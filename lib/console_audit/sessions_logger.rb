# frozen_string_literal: true

require "securerandom"

module ConsoleAudit
  # A console1984 sessions logger that enqueues audit records for asynchronous
  # delivery instead of writing them to the database. Implements console1984's
  # SessionsLogger duck-type in place of Console1984::SessionsLogger::Database:
  #
  #   start_session(username, reason) / finish_session
  #   before_executing(statements)    / after_executing(statements)
  #   start_sensitive_access(justification) / end_sensitive_access
  #   suspicious_commands_attempted(statements)
  #
  # `before_executing` is the important one: console1984 calls it *before* the
  # command runs, giving log-before-execute semantics even if the statement later
  # raises or the session dies. Because the enqueue is synchronous and in-band,
  # that guarantee survives — the record is durably queued before execution.
  #
  # Dropping the Database logger also drops console1984's Active Record
  # Encryption requirement and its migration.
  class SessionsLogger
    def initialize(config: ConsoleAudit.config, scrubber: nil)
      @config = config
      @scrubber = scrubber || Scrubber.new(filter_parameters: config.filter_parameters)
    end

    def start_session(username, reason)
      @session_id = SecureRandom.uuid
      @operator = username
      @reason = reason
      @started_at = now
      @command_count = 0
      @sensitive = false
      emit(event: "session_start")
    rescue => e
      warn("[console-audit] start_session failed (ignored): #{e.message}")
    end

    def finish_session
      emit(
        event: "session_end",
        duration_seconds: (now - (@started_at || now)).to_i,
        command_count: @command_count
      )
    rescue => e
      warn("[console-audit] finish_session failed (ignored): #{e.message}")
    ensure
      @session_id = @operator = @reason = @started_at = nil
    end

    def before_executing(statements)
      text = Array(statements).join("\n").strip
      return if text.empty?

      @command_count += 1 if @command_count
      emit(event: "command", command: @scrubber.scrub(text), sensitive: @sensitive)
    rescue => e
      warn("[console-audit] before_executing failed (ignored): #{e.message}")
    end

    def after_executing(statements)
      # No-op: we log before execution so a raising/aborting command is still
      # recorded. Kept to satisfy the interface.
    end

    # console1984 enters "sensitive" (unprotected) mode to reveal encrypted data /
    # reach protected URLs. We tag commands run while sensitive so Datadog
    # reflects the elevated access.
    def start_sensitive_access(justification)
      @sensitive = true
      emit(event: "sensitive_access_start", justification: justification)
    rescue => e
      warn("[console-audit] start_sensitive_access failed (ignored): #{e.message}")
    end

    def end_sensitive_access
      @sensitive = false
      emit(event: "sensitive_access_end")
    rescue => e
      warn("[console-audit] end_sensitive_access failed (ignored): #{e.message}")
    end

    def suspicious_commands_attempted(statements)
      emit(
        event: "suspicious_commands_attempted",
        command: @scrubber.scrub(Array(statements).join("\n"))
      )
    rescue => e
      warn("[console-audit] suspicious_commands_attempted failed (ignored): #{e.message}")
    end

    private

    def emit(event:, **attrs)
      # Pre-session guard: console1984 calls end_sensitive_access once while
      # entering protected mode, *before* start_session. Drop any event that
      # isn't a session_start when there's no active session, so we never emit a
      # record with a nil operator/session_id.
      return if @session_id.nil? && event != "session_start"

      Record.enqueue(
        Record.build(
          config: @config,
          event: event,
          session_id: @session_id,
          operator: @operator,
          reason: @reason,
          shell: "console1984",
          **attrs
        ),
        config: @config
      )
    end

    def now
      Time.now
    end
  end
end

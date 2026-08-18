# frozen_string_literal: true

require "securerandom"

module ConsoleAudit
  # Reason/command capture for the NON-interactive execution paths. console1984
  # only hooks the interactive `rails console`; `rake` tasks and `rails runner`
  # never enter its supervisor, so they'd otherwise run unlogged. The buildpack
  # restricts one-off dynos to rails/rake, so these two paths plus the
  # interactive console cover everything that can run.
  #
  # We detect the invocation at boot (Railtie `after_initialize`) rather than
  # prepending Rails::Command::RunnerCommand#perform: `rails runner` boots the app
  # *inside* perform, so a prepend can't be installed in time, and Thor's dispatch
  # doesn't reliably surface it anyway. At after_initialize the command is still
  # identifiable from Rake's task list / ARGV.
  #
  # Emits one best-effort, fail-open `noninteractive_command` record that
  # correlates with the api:dyno webhook exactly like an interactive session.
  #
  # KNOWN LIMITATION: a rake task that does not depend on `:environment` never
  # boots Rails, so after_initialize never runs and it isn't logged. Such a task
  # can't touch models/DB, and the buildpack blocks non-rails/rake commands, so
  # the exposure is limited — but it is a gap worth stating.
  module NoninteractiveAudit
    class << self
      # Called from the Railtie at after_initialize. Detects rake / rails runner
      # and logs it. Returns the kind logged (or nil for web/worker/console).
      def audit_current_command(config = ConsoleAudit.config)
        kind, command = detect

        return nil unless kind

        emit(config: config, kind: kind, command: command)
        kind
      rescue => e
        warn("[console-audit] noninteractive audit failed (ignored): #{e.message}")
        nil
      end

      private

      def detect
        if defined?(Rake) && Rake.application.top_level_tasks.any?
          ["rake", "rake #{Rake.application.top_level_tasks.join(" ")}"]
        elsif rails_runner?
          ["rails-runner", ARGV.join(" ")]
        end
      end

      # `rails runner CODE` reaches after_initialize with $PROGRAM_NAME ~ "rails"
      # and the code left in ARGV. The interactive `rails console` is excluded two
      # ways: it defines Rails::Console, and it reaches here with ARGV empty.
      # Rake is ruled out by the caller branch above.
      def rails_runner?
        return false if defined?(Rails::Console)

        $PROGRAM_NAME.end_with?("rails", "rails.rb") && !ARGV.empty?
      end

      # Enqueued, not sent: these paths get the same durability and the same
      # capture/delivery split as the interactive console. The enqueue happens
      # at after_initialize, so it precedes the task or runner code itself.
      def emit(config:, kind:, command:)
        scrubber = Scrubber.new(filter_parameters: config.filter_parameters)

        record = Record.build(
          config: config,
          event: "noninteractive_command",
          session_id: SecureRandom.uuid,
          # Read straight from the env — these paths never reach console1984's
          # username resolver or reason prompt.
          operator: ENV["CONSOLE_USER"],
          reason: ENV["CONSOLE_REASON"],
          shell: kind,
          command: scrubber.scrub(command.to_s)
        )

        Record.enqueue(record, config: config)
      end
    end
  end
end

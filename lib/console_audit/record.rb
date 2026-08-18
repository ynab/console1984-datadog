# frozen_string_literal: true

module ConsoleAudit
  # Builds and enqueues the audit records shared by the interactive
  # (console1984) and non-interactive (`rake` / `rails runner`) paths.
  #
  # THE CAPTURE / DELIVERY SPLIT. Only facts the one-off dyno is the sole place
  # to know belong in a record: the dyno UUID join key, the self-declared
  # operator and reason, the statement text, and the moment of capture. The
  # destination and the env / service / app attribution are stamped later, by
  # the worker and `datadog-proxy-service` — see DeliveryJob for why. Adding a
  # dyno-sourced environment or service field here would reintroduce exactly the
  # tampering vector the split exists to close.
  #
  # Keys are strings, and values primitives, because these cross a queue: the
  # record is an ActiveJob argument and has to survive its serializer.
  module Record
    class << self
      # @return [Hash] a string-keyed record ready to pass to DeliveryJob.
      def build(config:, event:, session_id:, operator:, reason:, shell:, **extra)
        {
          "event" => event.to_s,
          "session_id" => session_id,
          "operator" => operator,
          "reason" => reason,
          # The join key against the api:dyno webhook's data.id. Dyno *names*
          # (run.NNNN) are recycled, the UUID is not. nil unless the app has
          # runtime-dyno-metadata enabled — the reverse cross-check monitor
          # exists to catch that.
          "dyno_id" => config.dyno_id,
          "shell" => shell,
          # Stamped at capture, never re-stamped at delivery, so queue latency
          # cannot move a statement's recorded time.
          "timestamp" => timestamp
        }.merge(extra.transform_keys(&:to_s)).compact
      end

      # FAIL-OPEN. Enqueuing is the only delivery path, so a failed enqueue is
      # the only failure the console itself can encounter — and it must not
      # break the session. The resulting gap is caught in aggregate by the
      # missing-session cross-check against the api:dyno webhook.
      def enqueue(record, config: ConsoleAudit.config)
        silencing_logs { DeliveryJob.perform_later(record) }
        warn("[console-audit] queued #{record["event"]}") if config.debug
        true
      rescue => e
        warn("[console-audit] failed to queue #{record["event"]} (ignored): #{e.message}")
        false
      end

      private

      # ActiveJob's enqueue log subscriber writes an "Enqueued
      # ConsoleAudit::DeliveryJob" line — including the serialized record, so
      # the operator, the reason and the verbatim statement text — to the host
      # app's ordinary logger. On a Heroku one-off dyno that logger is stdout,
      # so it interleaves with the operator's own console session; and wherever
      # the host app ships its logs, it puts audit content outside the audit
      # pipeline, unscrubbed. Neither is wanted, so the enqueue is logged at
      # :error for the duration of the call. Delivery-side logging, which runs
      # on the worker, is untouched. See also DeliveryJob.log_arguments.
      def silencing_logs(&block)
        logger = ActiveJob::Base.logger
        # SemanticLogger::Base#silence and ActiveSupport::LoggerSilence#silence
        # both take a block and both default to :error; a logger with neither
        # (or none at all) simply isn't silenced.
        logger.respond_to?(:silence) ? logger.silence(&block) : block.call
      end

      def timestamp
        Time.now.utc.strftime("%Y-%m-%dT%H:%M:%S.%3NZ")
      end
    end
  end
end

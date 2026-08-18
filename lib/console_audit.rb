# frozen_string_literal: true

require "console_audit/version"
require "console_audit/config"
require "console_audit/scrubber"
require "console_audit/record"
# Required unconditionally, not behind the enabled? gate: the *worker* dyno has
# to be able to deserialize and perform the job, and it is never itself an
# audited console session.
require "console_audit/delivery_job"
require "console_audit/sessions_logger"
require "console_audit/noninteractive_audit"

# console_audit wraps Basecamp's console1984 as the console-hook engine and adds:
#   * a fail-open sessions logger that enqueues records as ActiveJobs, delivered
#     to `datadog-proxy-service` by a worker (no DB tables, no Active Record
#     Encryption, no network egress and no Datadog credential in the one-off dyno)
#   * PII scrubbing
#   * activation gated on the console-guard buildpack signal, not Rails.env
#   * an env-var reason resolver (CONSOLE_REASON), shared with the non-interactive paths
#   * capture of the non-interactive rake / rails runner paths
#
# In a Rails app, just add the gem — the Railtie wires console1984 automatically.
module ConsoleAudit
  class << self
    def config
      @config ||= Config.new
    end

    def configure
      yield(config)
    end

    def reset_configuration!
      @config = Config.new
    end
  end
end

require "console_audit/railtie" if defined?(Rails::Railtie)

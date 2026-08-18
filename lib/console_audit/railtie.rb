# frozen_string_literal: true

require "console1984"

module ConsoleAudit
  # Wires console1984 for the consuming app. All configuration happens in
  # `after_initialize` so that:
  #   * console1984's own engine initializer (which creates config.console1984)
  #     has already run, and
  #   * Rails.application.config.filter_parameters is fully populated.
  #
  # console1984 reads config.console1984 via `set_from` when the console starts
  # (after after_initialize), so setting it here takes effect for the session.
  class Railtie < ::Rails::Railtie
    config.after_initialize do
      cfg = ConsoleAudit.config

      # GATING — activate on the buildpack's signal, not the Rails env name.
      # console1984 activates when Rails.env ∈ protected_environments. We make the
      # CURRENT env "protected" only when CONSOLE_AUDIT_ENABLED=true (exported by
      # the buildpack after -e overrides, so it can't be unset). When disabled we
      # set a bogus env that can never match Rails.env — an empty array would be
      # dropped by console1984's `set_from` (blank values ignored), leaving the
      # default [:production] in place, so the sentinel is deliberate.
      Rails.application.config.console1984.protected_environments =
        cfg.enabled? ? [Rails.env.to_sym] : [:__console_audit_disabled__]

      next unless cfg.enabled?

      # Pull the app's filter_parameters for PII scrubbing unless already set.
      cfg.filter_parameters = Rails.application.config.filter_parameters if cfg.filter_parameters.empty?

      # Ship audit records to Datadog instead of console1984's DB logger.
      Rails.application.config.console1984.session_logger = ConsoleAudit::SessionsLogger.new(config: cfg)
      # Operator identity from the buildpack-enforced CONSOLE_USER (console1984's
      # default resolver; stated explicitly for clarity).
      Rails.application.config.console1984.username_resolver =
        Console1984::Username::EnvResolver.new("CONSOLE_USER")

      # Reason from CONSOLE_REASON instead of the interactive prompt.
      require "console_audit/reason_from_env"

      # Capture the non-interactive rake / rails runner paths.
      ConsoleAudit::NoninteractiveAudit.audit_current_command(cfg)
    end
  end
end

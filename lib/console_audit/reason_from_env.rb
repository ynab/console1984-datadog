# frozen_string_literal: true

module ConsoleAudit
  # Makes the session reason come from the CONSOLE_REASON env var instead of
  # console1984's interactive Reline prompt, so the reason is sourced identically
  # for interactive consoles and the non-interactive rake / rails runner paths
  # (which never reach console1984's prompt at all).
  #
  # console1984 exposes a pluggable `username_resolver` but hard-codes the reason
  # prompt (`Supervisor#ask_for_session_reason`, a private method from
  # Console1984::InputOutput). There's no config seam, so we prepend. Falls back
  # to the prompt when CONSOLE_REASON is absent (local use without the buildpack).
  #
  # This overrides a PRIVATE method: if console1984 renames/inlines it on upgrade,
  # this prepend silently stops taking effect and the console reverts to
  # prompting. That failure is silent, so it is guarded by a *behavioural* spec
  # (asserts the env reason is used with no prompt) rather than a presence check —
  # that spec is the signal on a dependabot bump.
  module ReasonFromEnv
    private

    def ask_for_session_reason
      reason = ENV["CONSOLE_REASON"].to_s.strip
      reason.empty? ? super : reason
    end
  end
end

if defined?(Console1984::Supervisor)
  Console1984::Supervisor.prepend(ConsoleAudit::ReasonFromEnv)
end

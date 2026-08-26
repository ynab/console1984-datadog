# frozen_string_literal: true

require_relative "lib/console_audit/version"

Gem::Specification.new do |spec|
  spec.name = "console_audit"
  spec.version = ConsoleAudit::VERSION
  spec.authors = ["YNAB"]
  spec.email = ["dev@ynab.com"]

  spec.summary = "Audit Rails console sessions to Datadog, using console1984 as the engine"
  spec.description = "Wraps Basecamp's console1984 with a fail-open sessions logger that enqueues " \
                     "audit records as ActiveJobs (delivered to a log-forwarding proxy service by a worker), " \
                     "PII scrubbing, buildpack-signal activation, an env-var reason resolver, " \
                     "and capture of the non-interactive rake / rails runner paths."
  spec.homepage = "https://github.com/ynab/console1984-datadog"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.1"

  # This gem is consumed from a git tag, never pushed to a gem server. A
  # non-URI `allowed_push_host` makes a bare `gem push` fail before it opens a
  # connection. It does not stop an explicit `gem push --host`.
  spec.metadata = {
    "allowed_push_host" => "none",
    "source_code_uri" => spec.homepage,
    "changelog_uri" => "#{spec.homepage}/blob/main/CHANGELOG.md",
    "bug_tracker_uri" => "#{spec.homepage}/issues"
  }

  spec.files = Dir["lib/**/*", "README.md", "LICENSE", "CHANGELOG.md"]
  spec.require_paths = ["lib"]

  # console1984 is the console-hook engine; we supply the logger + gating.
  spec.add_dependency "console1984", "~> 0.2.4"
  spec.add_dependency "railties", ">= 7.1"
  spec.add_dependency "activesupport", ">= 7.1"
  # Every audit record is delivered by enqueuing a job. 7.1 is the floor for the
  # `:polynomially_longer` retry curve the delivery job relies on.
  spec.add_dependency "activejob", ">= 7.1"
end

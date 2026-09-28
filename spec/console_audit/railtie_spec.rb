# frozen_string_literal: true

require "spec_helper"
require "json"
require "tmpdir"

# The railtie does its work in `after_initialize`, so these boot a real (if
# tiny) Rails application rather than calling the block directly. That ordering
# is the point: `Rails::Console` reads `config.disable_sandbox` after the app
# is booted, so only a booted app proves the setting lands in time.
#
# A Rails application can only be initialized once per process — engine paths
# are frozen on boot — so each case runs in a forked child.
RSpec.describe ConsoleAudit::Railtie do
  # @return [Object] whatever the block returns in the child, JSON round-tripped.
  def in_forked_app(enabled:, before_boot: nil)
    reader, writer = IO.pipe

    pid = fork do
      reader.close
      ENV["CONSOLE_AUDIT_ENABLED"] = enabled
      before_boot&.call
      app = Class.new(Rails::Application) do
        config.eager_load = false
        config.logger = Logger.new(IO::NULL)
        config.secret_key_base = "x" * 64
        config.root = Dir.mktmpdir
      end
      app.initialize!
      writer.write(JSON.generate([yield(app)]))
      writer.close
      exit!(0)
    end

    writer.close
    payload = reader.read
    Process.wait(pid)
    raise "child failed to boot" if payload.empty?

    # Wrapped in an array so bare `true`/`false`/`nil` survive the round trip.
    JSON.parse(payload).first
  end

  it "disables sandboxed consoles when auditing is enabled" do
    result = in_forked_app(enabled: "true") { |app| app.config.disable_sandbox }

    expect(result).to be(true)
  end

  # Guards against the assignment drifting above the `next unless cfg.enabled?`
  # line, which would take sandbox away from apps that aren't being audited.
  it "leaves the setting alone when auditing is disabled" do
    result = in_forked_app(enabled: "false") { |app| app.config.disable_sandbox }

    expect(result).to be(false)
  end

  describe "non-interactive audit" do
    # Stands in for a gem later in the Gemfile than console_audit whose
    # after_initialize the enqueue depends on (rails_semantic_logger).
    def boot_with_later_gem(enabled:)
      order = []
      before_boot = lambda do
        ActiveSupport.on_load(:after_initialize) { order << "later_gem" }
        ConsoleAudit::NoninteractiveAudit.define_singleton_method(:audit_current_command) { |*| order << "audit" }
      end

      in_forked_app(enabled: enabled, before_boot: before_boot) { order }
    end

    it "runs after gems loaded later than console_audit have initialized" do
      expect(boot_with_later_gem(enabled: "true")).to eq(%w[later_gem audit])
    end

    it "does not run when auditing is disabled" do
      expect(boot_with_later_gem(enabled: "false")).to eq(%w[later_gem])
    end
  end
end

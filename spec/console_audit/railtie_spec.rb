# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

# The railtie does its work in `after_initialize`, so these boot a real (if
# tiny) Rails application rather than calling the block directly. That ordering
# is the point: `Rails::Console` reads `config.disable_sandbox` after the app
# is booted, so only a booted app proves the setting lands in time.
#
# A Rails application can only be initialized once per process — engine paths
# are frozen on boot — so each case runs in a forked child.
RSpec.describe ConsoleAudit::Railtie do
  # @return [Object] whatever the block returns in the child, marshalled back.
  def in_forked_app(enabled:)
    reader, writer = IO.pipe

    pid = fork do
      reader.close
      ENV["CONSOLE_AUDIT_ENABLED"] = enabled
      app = Class.new(Rails::Application) do
        config.eager_load = false
        config.logger = Logger.new(IO::NULL)
        config.secret_key_base = "x" * 64
        config.root = Dir.mktmpdir
      end
      app.initialize!
      writer.write(Marshal.dump(yield(app)))
      writer.close
      exit!(0)
    end

    writer.close
    payload = reader.read
    Process.wait(pid)
    raise "child failed to boot" if payload.empty?

    Marshal.load(payload)
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
end

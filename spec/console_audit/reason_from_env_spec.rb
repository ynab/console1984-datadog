# frozen_string_literal: true

require "spec_helper"

# Behavioural guard for the reason resolver. This drives console1984's REAL
# session-start path (Supervisor#start_session) rather than calling the patched
# method directly — so if console1984 renames/inlines ask_for_session_reason on
# an upgrade, this fails (the prompt would be reached) instead of silently
# reverting to prompting. That is the whole point of the test.
RSpec.describe ConsoleAudit::ReasonFromEnv do
  let(:captured) { {} }

  let(:fake_logger) do
    c = captured
    Object.new.tap do |logger|
      logger.define_singleton_method(:start_session) { |user, reason|
        c[:user] = user
        c[:reason] = reason
      }
    end
  end

  before do
    @old_reason = ENV["CONSOLE_REASON"]
    @old_user = ENV["CONSOLE_USER"]
    @old_logger = Console1984.config.session_logger
    @old_resolver = Console1984.config.username_resolver

    Console1984.config.session_logger = fake_logger
    Console1984.config.username_resolver = Console1984::Username::EnvResolver.new("CONSOLE_USER")
    ENV["CONSOLE_USER"] = "jdoe"

    # Any attempt to prompt is a failure unless a test opts into it.
    allow(Reline).to receive(:readline).and_raise("should not prompt when CONSOLE_REASON is set")
  end

  after do
    ENV["CONSOLE_REASON"] = @old_reason
    ENV["CONSOLE_USER"] = @old_user
    Console1984.config.session_logger = @old_logger
    Console1984.config.username_resolver = @old_resolver
  end

  it "is prepended onto Console1984::Supervisor" do
    expect(Console1984::Supervisor.ancestors).to include(described_class)
  end

  it "uses CONSOLE_REASON for the session reason without prompting" do
    ENV["CONSOLE_REASON"] = "INV-99 from env"

    Console1984.supervisor.send(:start_session)

    expect(captured[:reason]).to eq("INV-99 from env")
    expect(captured[:user]).to eq("jdoe")
  end

  it "falls back to the interactive prompt when CONSOLE_REASON is absent" do
    ENV.delete("CONSOLE_REASON")
    allow(Reline).to receive(:readline).and_return("typed reason")

    Console1984.supervisor.send(:start_session)

    expect(captured[:reason]).to eq("typed reason")
    expect(Reline).to have_received(:readline)
  end
end

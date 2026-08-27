# frozen_string_literal: true

require "spec_helper"

RSpec.describe ConsoleAudit::SessionsLogger do
  let(:config) do
    ConsoleAudit::Config.new.tap do |c|
      c.filter_parameters = %i[password email]
    end
  end

  subject(:logger) { described_class.new(config: config) }

  def events = enqueued_records.map { |r| r["event"] }

  describe "#start_session" do
    it "enqueues a session_start carrying operator, reason and a session id" do
      logger.start_session("jdoe", "INV-42 investigate webhook gap")

      record = enqueued_records.last
      expect(record["event"]).to eq("session_start")
      expect(record["operator"]).to eq("jdoe")
      expect(record["reason"]).to eq("INV-42 investigate webhook gap")
      expect(record["session_id"]).not_to be_nil
      expect(record["timestamp"]).to match(/\A\d{4}-\d{2}-\d{2}T[\d:.]+Z\z/)
    end

    it "carries the dyno UUID join key when runtime-dyno-metadata is enabled" do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("HEROKU_DYNO_ID").and_return("d1e2f3a4-0000-4000-8000-abcdefabcdef")

      described_class.new(config: ConsoleAudit::Config.new).start_session("jdoe", "INV-42")

      expect(enqueued_records.last["dyno_id"]).to eq("d1e2f3a4-0000-4000-8000-abcdefabcdef")
    end
  end

  # The capture/delivery split is a security property, not a formatting choice:
  # anything read from the one-off dyno's env can be overridden with
  # `heroku run -e`, so a dyno-stamped env/service tag would let a record keep
  # flowing to Datadog while dropping out of our production-scoped monitors.
  describe "the capture / delivery split" do
    it "does not stamp any delivery-side attribution into the record" do
      stub_const("ENV", ENV.to_hash.merge("HEROKU_DYNO_ID" => "d1e2f3a4-0000-4000-8000-abcdefabcdef"))
      described_class.new(config: ConsoleAudit::Config.new).start_session("jdoe", "INV-42")

      record = enqueued_records.last
      expect(record.keys).to contain_exactly(
        "event", "session_id", "operator", "reason", "dyno_id", "shell", "timestamp"
      )
      %w[ddsource ddtags env service hostname app version dyno].each do |key|
        expect(record).not_to have_key(key)
      end
    end
  end

  describe "#before_executing" do
    before { logger.start_session("jdoe", "INV-42") }

    it "records the statement (console1984 calls this BEFORE execution)" do
      logger.before_executing("Budget.count")

      record = enqueued_records.last
      expect(record["event"]).to eq("command")
      expect(record["command"]).to eq("Budget.count")
      expect(record["session_id"]).to eq(enqueued_records.first["session_id"])
    end

    it "scrubs PII before it leaves the process" do
      logger.before_executing('User.create(password: "hunter2")')

      command = enqueued_records.last["command"]
      expect(command).to include('password: "[FILTERED]"')
      expect(command).not_to include("hunter2")
    end

    it "skips blank statements" do
      expect { logger.before_executing("   ") }.not_to(change { enqueued_records.size })
    end

    # "Durably queued before the statement runs" is the log-before-execute
    # guarantee; it only holds if the enqueue is synchronous and in-band.
    it "has enqueued the record by the time it returns" do
      logger.before_executing("Budget.destroy_all")

      expect(enqueued_records.last["command"]).to eq("Budget.destroy_all")
    end
  end

  describe "pre-session guard" do
    # console1984 calls end_sensitive_access once while entering protected mode,
    # BEFORE start_session. That event must be dropped (no nil-operator noise).
    it "drops events emitted before a session has started" do
      logger.end_sensitive_access
      expect(enqueued_records).to be_empty
    end

    it "emits sensitive-access events once a session is active" do
      logger.start_session("jdoe", "INV-42")
      logger.start_sensitive_access("reveal token")
      logger.before_executing("SomeModel.first")
      logger.end_sensitive_access

      cmd = enqueued_records.find { |r| r["event"] == "command" }
      expect(cmd["sensitive"]).to be(true)
      expect(events).to include("sensitive_access_start", "sensitive_access_end")
    end
  end

  describe "#finish_session" do
    it "emits a session_end with the command count and duration" do
      logger.start_session("jdoe", "INV-42")
      logger.before_executing("Budget.count")
      logger.finish_session

      record = enqueued_records.last
      expect(record["event"]).to eq("session_end")
      expect(record["command_count"]).to eq(1)
      expect(record["duration_seconds"]).to be >= 0
    end
  end

  # console1984 reaches finish_session only through Supervisor#stop, which only
  # exit_irb calls, which CommandExecutor only calls after a forbidden command
  # executed. Nothing closes a session that ends with a normal `exit`, so
  # start_session arms it. Without this, session_end is emitted for roughly no
  # real session and command_count/duration_seconds never exist.
  describe "closing the session at process exit" do
    def capture_at_exit(logger)
      captured = nil
      allow(logger).to receive(:at_exit) { |&block| captured = block }
      yield
      captured
    end

    it "arms a handler that emits session_end" do
      handler = capture_at_exit(logger) { logger.start_session("jdoe", "INV-42") }
      logger.before_executing("Budget.count")

      expect(handler).not_to be_nil
      expect { handler.call }.to change { events.count("session_end") }.by(1)
      expect(enqueued_records.last["command_count"]).to eq(1)
    end

    it "arms only one handler per session" do
      handlers = []
      allow(logger).to receive(:at_exit) { |&block| handlers << block }

      logger.start_session("jdoe", "INV-42")
      logger.start_session("jdoe", "INV-43")

      expect(handlers.size).to eq(1)
    end

    it "does not emit a second session_end when console1984 already closed the session" do
      handler = capture_at_exit(logger) { logger.start_session("jdoe", "INV-42") }
      logger.finish_session

      expect { handler.call }.not_to(change { events.count("session_end") })
    end

    # Guards the duck-type name across a console1984 upgrade: a rename would
    # silently take out both the forbidden-command path and the at_exit above.
    it "is the method console1984's supervisor calls when it stops a session" do
      allow(Console1984).to receive(:session_logger).and_return(logger)

      expect(logger).to receive(:finish_session)

      Console1984::Supervisor.new.stop
    end
  end

  # FAIL-OPEN: with enqueuing as the only delivery path, a failed enqueue is the
  # only failure the console can hit — and it must never break the session. The
  # resulting gap is caught by the missing-session cross-check.
  describe "fail-open behaviour" do
    before do
      allow(ConsoleAudit::DeliveryJob).to receive(:perform_later)
        .and_raise(RuntimeError, "queue backend unreachable")
    end

    it "never raises out of any logging hook" do
      expect {
        logger.start_session("jdoe", "INV-42")
        logger.before_executing("Budget.count")
        logger.start_sensitive_access("x")
        logger.end_sensitive_access
        logger.suspicious_commands_attempted("ConsoleClass = nil")
        logger.finish_session
      }.not_to raise_error
    end

    it "warns locally rather than failing silently" do
      expect { logger.start_session("jdoe", "INV-42") }
        .to output(/failed to queue session_start/).to_stderr
    end
  end
end

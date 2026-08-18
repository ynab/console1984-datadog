# frozen_string_literal: true

require "spec_helper"

RSpec.describe ConsoleAudit::NoninteractiveAudit do
  describe ".audit_current_command" do
    let(:config) { ConsoleAudit::Config.new }

    before do
      allow(described_class).to receive(:detect).and_return(["rake", "rake db:migrate"])
      stub_const("ENV", ENV.to_hash.merge(
        "CONSOLE_USER" => "jdoe",
        "CONSOLE_REASON" => "https://github.com/example-org/example-app/actions/runs/1"
      ))
    end

    it "enqueues one noninteractive_command record" do
      described_class.audit_current_command(config)

      record = enqueued_records.last
      expect(record["event"]).to eq("noninteractive_command")
      expect(record["command"]).to eq("rake db:migrate")
      expect(record["shell"]).to eq("rake")
      expect(record["operator"]).to eq("jdoe")
      expect(record["reason"]).to eq("https://github.com/example-org/example-app/actions/runs/1")
      expect(record["session_id"]).not_to be_nil
    end

    it "carries no delivery-side attribution, exactly like the interactive path" do
      described_class.audit_current_command(config)

      %w[ddsource ddtags env service hostname app version dyno].each do |key|
        expect(enqueued_records.last).not_to have_key(key)
      end
    end

    it "scrubs PII from the command" do
      allow(described_class).to receive(:detect)
        .and_return(["rails-runner", 'User.find_by(email: "someone@gmail.com")'])
      config.filter_parameters = %i[email]

      described_class.audit_current_command(config)

      expect(enqueued_records.last["command"]).not_to include("someone@gmail.com")
    end

    it "enqueues nothing for an ordinary web/worker boot" do
      allow(described_class).to receive(:detect).and_return(nil)

      expect(described_class.audit_current_command(config)).to be_nil
      expect(enqueued_records).to be_empty
    end

    it "is fail-open when the queue backend is unreachable" do
      allow(ConsoleAudit::DeliveryJob).to receive(:perform_later)
        .and_raise(RuntimeError, "queue backend unreachable")

      expect { described_class.audit_current_command(config) }.not_to raise_error
    end
  end

  describe ".detect" do
    subject(:detect) { described_class.send(:detect) }

    around do |example|
      original = ARGV.dup
      example.run
      ARGV.replace(original)
    end

    it "classifies a rake invocation with its top-level tasks" do
      rake = double(application: double(top_level_tasks: %w[db:migrate stats]))
      stub_const("Rake", rake)

      expect(detect).to eq(["rake", "rake db:migrate stats"])
    end

    it "classifies a `rails runner` invocation from ARGV" do
      hide_const("Rake") if defined?(Rake)
      ARGV.replace(["User.count"])
      allow(described_class).to receive(:rails_runner?).and_return(true)

      expect(detect).to eq(["rails-runner", "User.count"])
    end

    it "returns nil for ordinary boots (web/worker/console)" do
      hide_const("Rake") if defined?(Rake)
      ARGV.replace([])
      allow(described_class).to receive(:rails_runner?).and_return(false)

      expect(detect).to be_nil
    end

    describe ".rails_runner?" do
      subject(:rails_runner?) { described_class.send(:rails_runner?) }

      it "is false while an interactive console is loaded" do
        stub_const("Rails::Console", Class.new)
        ARGV.replace(["whatever"])
        expect(rails_runner?).to be(false)
      end
    end
  end
end

# frozen_string_literal: true

require "spec_helper"
# The enqueue log line under test comes from ActiveJob's own log subscriber,
# which only exists once this is loaded.
require "active_job/log_subscriber"

RSpec.describe ConsoleAudit::Record do
  describe ".enqueue" do
    let(:record) { {"event" => "command", "operator" => "operator@example.com", "command" => "User.first"} }
    let(:log) { StringIO.new }

    around do |example|
      previous = ActiveJob::Base.logger
      ActiveJob::Base.logger = ActiveSupport::Logger.new(log)
      example.run
    ensure
      ActiveJob::Base.logger = previous
    end

    # An audit record's only route out of the dyno is the audit pipeline. The
    # enqueue log line would put it on a second route — stdout on a one-off
    # dyno, and from there wherever the host app ships its logs — carrying the
    # operator, the reason and the verbatim statement, unscrubbed.
    it "does not log the enqueue to the host app's logger" do
      described_class.enqueue(record)

      expect(log.string).to be_empty
    end

    it "still enqueues the record" do
      described_class.enqueue(record)

      expect(enqueued_records.last).to eq(record)
    end

    # Belt and braces for a host app whose logger the silencing does not reach:
    # the line may survive, but never the record it carries.
    it "keeps the record out of the enqueue line for a logger that cannot be silenced" do
      unsilenceable = Class.new(SimpleDelegator) do
        def respond_to_missing?(name, include_private = false)
          name != :silence && super
        end
      end.new(ActiveJob::Base.logger)
      allow(ActiveJob::Base).to receive(:logger).and_return(unsilenceable)

      described_class.enqueue(record)

      expect(log.string).to include("Enqueued ConsoleAudit::DeliveryJob")
      expect(log.string).not_to include("User.first")
      expect(log.string).not_to include("operator@example.com")
    end

    # FAIL-OPEN: silencing must not become a new way for the console to break.
    it "swallows an enqueue failure as before" do
      allow(ConsoleAudit::DeliveryJob).to receive(:perform_later).and_raise("queue backend unreachable")

      expect(described_class.enqueue(record)).to be(false)
    end
  end
end

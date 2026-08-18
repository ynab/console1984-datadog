# frozen_string_literal: true

# console1984 is a Rails engine (its class body references ::Rails::Engine), so
# Rails must be loaded before it.
require "rails"
require "console1984"
# console1984 loads rainbow lazily inside supervisor.install (not called in unit
# tests); require it up front so its interactive prompt path is exercisable.
require "rainbow"
require "console_audit"
require "console_audit/reason_from_env"
require "active_job"
require "webmock/rspec"

WebMock.disable_net_connect!(allow_localhost: true)

ActiveJob::Base.queue_adapter = :test
ActiveJob::Base.logger = Logger.new(IO::NULL)

RSpec.configure do |config|
  config.expect_with(:rspec) { |c| c.syntax = :expect }
  config.include(ActiveJob::TestHelper)

  config.before do
    ConsoleAudit.configure do |c|
      c.filter_parameters = %i[passw email secret token _key]
    end
    ActiveJob::Base.queue_adapter.enqueued_jobs.clear
    ActiveJob::Base.queue_adapter.performed_jobs.clear
  end

  config.after do
    ConsoleAudit.reset_configuration!
  end
end

# The records enqueued by the gem, in order, as the worker will receive them —
# deserialized, so these assertions also prove the record survives ActiveJob's
# argument serializer intact (it is stored serialized, with the adapter's
# `_aj_symbol_keys` marker, until deserialized here).
def enqueued_records
  ActiveJob::Base.queue_adapter.enqueued_jobs
    .select { |job| job[:job] == ConsoleAudit::DeliveryJob }
    .map { |job| ActiveJob::Arguments.deserialize(job[:args]).first }
end

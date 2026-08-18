# frozen_string_literal: true

require "spec_helper"

RSpec.describe ConsoleAudit::Scrubber do
  subject(:scrubber) do
    described_class.new(filter_parameters: %i[passw secret token email _key])
  end

  it "filters values assigned to sensitive keys (symbol-colon syntax)" do
    expect(scrubber.scrub('User.create(password: "hunter2")'))
      .to eq('User.create(password: "[FILTERED]")')
  end

  it "filters values assigned to sensitive keys (hash-rocket syntax)" do
    expect(scrubber.scrub('h = { "secret" => "abc123" }'))
      .to eq('h = { "secret" => "[FILTERED]" }')
  end

  it "redacts an email that is the whole quoted literal" do
    scrubbed = scrubber.scrub('User.find_by(login: "customer@gmail.com")')
    expect(scrubbed).to include("[FILTERED]")
    expect(scrubbed).not_to include("customer@gmail.com")
  end

  # No domain is exempt: the operator identity is carried in the record's own
  # `operator` field and never passes through the scrubber, so there is nothing
  # an allowlist would protect.
  it "redacts an internal-looking email just like any other" do
    scrubbed = scrubber.scrub('User.find_by(login: "operator@example.com")')
    expect(scrubbed).not_to include("operator@example.com")
  end

  # Documents the deliberate scope: an email embedded in a larger string is NOT
  # redacted (whole-literal only) — see the class comment / README.
  it "does not redact emails embedded in larger strings (by design)" do
    expect(scrubber.scrub('note = "ping customer@gmail.com now"'))
      .to include("customer@gmail.com")
  end

  it "leaves non-sensitive commands untouched" do
    cmd = "Budget.where(active: true).count"
    expect(scrubber.scrub(cmd)).to eq(cmd)
  end
end

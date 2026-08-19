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

  describe "values containing escaped quotes" do
    it "does not leak a double-quoted value with an escaped quote" do
      expect(scrubber.scrub('User.create(password: "he said \"hunter2\" ok")'))
        .to eq('User.create(password: "[FILTERED]")')
    end

    it "does not leak a single-quoted value with an escaped quote" do
      expect(scrubber.scrub(%q{User.create(password: 'don\'t tell')}))
        .to eq(%q{User.create(password: '[FILTERED]')})
    end

    # An escaped backslash is one unit, so the quote after it really does close.
    # The literal below is source text containing `password: "a\\b"`.
    it "does not leak a value ending in an escaped backslash" do
      expect(scrubber.scrub('x = { password: "a\\\\b" }'))
        .to eq('x = { password: "[FILTERED]" }')
    end

    it "still stops at the real closing quote" do
      expect(scrubber.scrub('u.update(password: "a", name: "bob")'))
        .to eq('u.update(password: "[FILTERED]", name: "bob")')
    end

    it "handles an escaped quote in hash-rocket syntax too" do
      expect(scrubber.scrub('h = { "secret" => "a\"b" }'))
        .to eq('h = { "secret" => "[FILTERED]" }')
    end

    # The value matcher must not cross a newline: statements arrive joined with
    # "\n", and an unbalanced quote on one line must not swallow the next line
    # and hide a genuine assignment from the scan.
    it "does not let an unbalanced quote hide a later statement" do
      text = %(Rails.logger.info "user's password: " + p\nUser.create(password: "hunter2"))

      expect(scrubber.scrub(text)).not_to include("hunter2")
    end
  end

  # An audit record should differ from what the operator typed only in the
  # redacted span; the replacement used to insert a space before the arrow.
  it "preserves the original spacing around a hash rocket" do
    expect(scrubber.scrub('h = {"secret"=>"abc123"}'))
      .to eq('h = {"secret"=>"[FILTERED]"}')
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

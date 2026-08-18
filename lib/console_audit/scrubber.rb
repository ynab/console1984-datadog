# frozen_string_literal: true

require "active_support/parameter_filter"

module ConsoleAudit
  # PII scrubbing for command text before it leaves the dyno for Datadog.
  #
  # This is a *secondary* net. The primary protections are that console1984 logs
  # statements (not their output) and that we filter values assigned to
  # sensitive-looking keys. Regex-on-source can only redact string literals — it
  # cannot redact `password: params[:p]` or a variable reference.
  #
  # The email pattern deliberately only redacts an address that is the *entire*
  # quoted literal: email grammars are broad, and a loose pattern chews through
  # paths and LIKE fragments. Emails embedded in larger strings therefore pass
  # through — an accepted trade-off (see README).
  #
  # Only command text passes through here. The operator identity (CONSOLE_USER)
  # is an audit field, not PII to redact, and never reaches the scrubber.
  class Scrubber
    EMAIL_PATTERN = /(?<=["'])[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}(?=["'])/

    # key: "value" or key: 'value'  (Ruby keyword / symbol-colon syntax)
    SYMBOL_COLON_PATTERN = /(\b\w+)(:\s*)(["'])(.*?)\3/
    # :key => "value" or "key" => "value"  (hash-rocket syntax)
    HASH_ROCKET_PATTERN = /(:|["'])(\w+)(["'])?\s*(=>\s*)(["'])(.*?)\5/

    def initialize(filter_parameters:)
      @filter_parameters = filter_parameters
    end

    def scrub(text)
      scrubbed = text.to_s.dup

      scrubbed.gsub!(SYMBOL_COLON_PATTERN) do
        key, separator, quote, _value = $1, $2, $3, $4
        sensitive_key?(key) ? "#{key}#{separator}#{quote}[FILTERED]#{quote}" : $&
      end

      scrubbed.gsub!(HASH_ROCKET_PATTERN) do
        prefix, key, closing_quote, arrow, quote, _value = $1, $2, $3, $4, $5, $6
        if sensitive_key?(key)
          "#{prefix}#{key}#{closing_quote} #{arrow}#{quote}[FILTERED]#{quote}"
        else
          $&
        end
      end

      scrubbed.gsub!(EMAIL_PATTERN, "[FILTERED]")

      scrubbed
    end

    private

    def sensitive_key?(key)
      parameter_filter.filter(key => "x")[key] == "[FILTERED]"
    end

    def parameter_filter
      @parameter_filter ||= ActiveSupport::ParameterFilter.new(@filter_parameters)
    end
  end
end

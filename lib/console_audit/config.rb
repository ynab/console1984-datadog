# frozen_string_literal: true

require "active_support/core_ext/object/blank"

module ConsoleAudit
  # What the one-off dyno needs to know in order to *capture* a record.
  #
  # Deliberately small. There is no Datadog API key, site, environment, service
  # or source here: the gem sends nothing to Datadog, and the env / service /
  # app attribution is stamped at delivery rather than read from the dyno's
  # environment (see Record and DeliveryJob). An operator can override any env
  # var on a one-off dyno with `heroku run -e`, so anything read here is
  # untrusted by construction — which is why only the join key, the
  # self-declared identity, and the statement text are read here at all.
  class Config
    attr_accessor :debug, :filter_parameters

    attr_reader :dyno_id

    def initialize
      # The dyno UUID is the robust join key against the api:dyno webhook
      # (data.id): dyno *names* (run.NNNN) get recycled, the UUID does not.
      # Requires runtime-dyno-metadata enabled on the app.
      #
      # Uses `.presence` rather than an ENV.fetch default because
      # runtime-dyno-metadata can leave this present-but-empty, and an empty
      # string is a silently-broken join key where nil is a visibly absent one.
      @dyno_id = ENV["HEROKU_DYNO_ID"].presence
      @debug = ENV["CONSOLE_AUDIT_DEBUG"] == "1"
      @filter_parameters = []
    end

    # True once the buildpack (or a local opt-in) has signalled that this session
    # should be audited. The buildpack exports this after -e overrides apply, so
    # it can't be unset by the operator.
    def enabled?
      ENV["CONSOLE_AUDIT_ENABLED"] == "true"
    end
  end
end

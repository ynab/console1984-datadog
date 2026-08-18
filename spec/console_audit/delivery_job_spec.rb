# frozen_string_literal: true

require "spec_helper"

RSpec.describe ConsoleAudit::DeliveryJob do
  let(:proxy_url) { "https://datadog-proxy-service.example.com/console-audit" }
  let(:record) do
    {
      "event" => "command",
      "session_id" => "11111111-2222-3333-4444-555555555555",
      "operator" => "jdoe",
      "reason" => "INV-42",
      "dyno_id" => "d1e2f3a4-0000-4000-8000-abcdefabcdef",
      "shell" => "console1984",
      "command" => "Budget.count",
      "timestamp" => "2026-08-12T10:00:00.000Z"
    }
  end

  before do
    stub_const("ENV", ENV.to_hash.merge(described_class::PROXY_URL_VAR => proxy_url))
  end

  def perform = described_class.new(record).perform(record)

  it "POSTs the record to the proxy URL" do
    stub = stub_request(:post, proxy_url).to_return(status: 202)

    perform

    expect(stub).to have_been_requested
    expect(WebMock).to have_requested(:post, proxy_url)
      .with(headers: {"Content-Type" => "application/json"}) do |req|
        JSON.parse(req.body) == record
      end
  end

  # The gem holds no Datadog credential of its own; `datadog-proxy-service` is the only
  # thing that talks to Datadog.
  it "sends no Datadog API key" do
    stub_request(:post, proxy_url).to_return(status: 202)

    perform

    expect(WebMock).to have_requested(:post, proxy_url)
      .with { |req| !req.headers.keys.any? { |h| h.casecmp("dd-api-key").zero? } }
  end

  it "preserves the capture timestamp rather than re-stamping at delivery" do
    stub_request(:post, proxy_url).to_return(status: 202)

    perform

    expect(WebMock).to have_requested(:post, proxy_url)
      .with { |req| JSON.parse(req.body)["timestamp"] == "2026-08-12T10:00:00.000Z" }
  end

  # The other half of the capture/delivery split: identity comes from the
  # worker's own config vars, which `heroku run -e` on the audited dyno cannot
  # reach. `datadog-proxy-service` maps these onto the Datadog service/env/host facets.
  describe "attribution stamped at delivery" do
    def stub_app_env(vars)
      stub_const("ENV", ENV.to_hash.merge(described_class::PROXY_URL_VAR => proxy_url).merge(vars))
    end

    it "stamps service, env, app and version from the worker's environment" do
      stub_app_env(
        "DD_SERVICE" => "billing-api",
        "DD_ENV" => "production",
        "HEROKU_APP_NAME" => "billing-api-production",
        "DD_VERSION" => "a1b2c3d"
      )
      stub_request(:post, proxy_url).to_return(status: 202)

      perform

      expect(WebMock).to have_requested(:post, proxy_url).with { |req|
        body = JSON.parse(req.body)
        body["service"] == "billing-api" && body["env"] == "production" &&
          body["app"] == "billing-api-production" && body["version"] == "a1b2c3d"
      }
    end

    it "falls back to the app name for service and the slug commit for version" do
      stub_app_env(
        "DD_SERVICE" => nil, "DD_VERSION" => nil,
        "HEROKU_APP_NAME" => "worker-app-staging", "HEROKU_SLUG_COMMIT" => "deadbee"
      )
      stub_request(:post, proxy_url).to_return(status: 202)

      perform

      expect(WebMock).to have_requested(:post, proxy_url).with { |req|
        body = JSON.parse(req.body)
        body["service"] == "worker-app-staging" && body["version"] == "deadbee"
      }
    end

    # A present-but-empty tag is worse than an absent one: Datadog rejects
    # `env:` outright, and the proxy can only fall back if the key is gone.
    it "omits attribution keys whose config vars are unset or empty" do
      stub_app_env("DD_SERVICE" => "", "DD_ENV" => "", "HEROKU_APP_NAME" => nil, "DD_VERSION" => nil)
      stub_request(:post, proxy_url).to_return(status: 202)

      perform

      expect(WebMock).to have_requested(:post, proxy_url).with { |req|
        body = JSON.parse(req.body)
        %w[service env app version].none? { |key| body.key?(key) }
      }
    end

    it "does not overwrite the fields captured in the dyno" do
      stub_app_env("DD_SERVICE" => "billing-api", "DD_ENV" => "production")
      stub_request(:post, proxy_url).to_return(status: 202)

      perform

      expect(WebMock).to have_requested(:post, proxy_url).with { |req|
        JSON.parse(req.body).slice(*record.keys) == record
      }
    end
  end

  describe "authentication" do
    let(:proxy_url) { "https://billing-api-production:s3cr3t@datadog-proxy-service.example.com/webhooks/console_audit" }
    let(:clean_url) { "https://datadog-proxy-service.example.com/webhooks/console_audit" }

    # Net::HTTP does not apply a URI's userinfo on its own, so without this the
    # credential in the URL would be silently dropped and every delivery 401.
    it "authenticates with the credential embedded in the proxy URL" do
      stub_request(:post, clean_url).to_return(status: 202)

      perform

      expect(WebMock).to have_requested(:post, clean_url)
        .with(basic_auth: ["billing-api-production", "s3cr3t"])
    end

    it "unescapes a percent-encoded credential" do
      stub_const(
        "ENV",
        ENV.to_hash.merge(
          described_class::PROXY_URL_VAR =>
            "https://app:p%40ss%3Aword@datadog-proxy-service.example.com/webhooks/console_audit"
        )
      )
      stub_request(:post, clean_url).to_return(status: 202)

      perform

      expect(WebMock).to have_requested(:post, clean_url)
        .with(basic_auth: ["app", "p@ss:word"])
    end

    it "keeps the credential out of the request line" do
      stub_request(:post, clean_url).to_return(status: 202)

      perform

      expect(WebMock).to have_requested(:post, clean_url)
        .with { |req| !req.uri.to_s.include?("s3cr3t") }
    end

    it "sends no Authorization header when the URL carries no credential" do
      stub_const("ENV", ENV.to_hash.merge(described_class::PROXY_URL_VAR => clean_url))
      stub_request(:post, clean_url).to_return(status: 202)

      perform

      expect(WebMock).to have_requested(:post, clean_url)
        .with { |req| !req.headers.keys.any? { |h| h.casecmp("authorization").zero? } }
    end

    # URI::Error quotes the offending URL, which carries the password. It must
    # not reach a log, an exception tracker, or the jobs UI.
    it "raises a retryable error that does not quote the URL when it is malformed" do
      stub_const(
        "ENV",
        ENV.to_hash.merge(described_class::PROXY_URL_VAR => "https://app:s3cr3t@bad host/path")
      )

      expect { perform }.to raise_error(described_class::DeliveryError) { |error|
        expect(error.message).not_to include("s3cr3t")
        expect(error.message).to include(described_class::PROXY_URL_VAR)
      }
    end
  end

  describe "retryable failures" do
    it "raises DeliveryError on a 5xx" do
      stub_request(:post, proxy_url).to_return(status: 503)

      expect { perform }.to raise_error(described_class::DeliveryError, /HTTP 503/)
    end

    it "raises DeliveryError on a 429" do
      stub_request(:post, proxy_url).to_return(status: 429)

      expect { perform }.to raise_error(described_class::DeliveryError, /HTTP 429/)
    end

    it "raises DeliveryError when the proxy is unreachable" do
      stub_request(:post, proxy_url).to_raise(Errno::ECONNREFUSED)

      expect { perform }.to raise_error(described_class::DeliveryError, /unreachable/)
    end

    # Retryable, not permanent: an unset config var is fixed by setting it, and
    # holding the record beats discarding an audit trail over an omission.
    it "raises DeliveryError when the proxy URL config var is unset" do
      stub_const("ENV", ENV.to_hash.except(described_class::PROXY_URL_VAR))

      expect { perform }.to raise_error(described_class::DeliveryError, /is not set/)
    end
  end

  describe "permanent failures" do
    it "raises PermanentDeliveryError on a 4xx the proxy will keep rejecting" do
      stub_request(:post, proxy_url).to_return(status: 422)

      expect { perform }.to raise_error(described_class::PermanentDeliveryError, /HTTP 422/)
    end
  end

  describe "retry policy" do
    # Solid Queue does not retry at all unless the job asks for it, so this
    # policy — not the adapter default — is what delivers the ~24h outage
    # resilience the gem promises. Guards the attempt count from drifting below
    # it: this is the un-jittered `:polynomially_longer` curve, which is the
    # lower bound on the real retry window.
    # Behavioural, not a presence check: `retry_on` with an unrecognised wait
    # would let the record be dropped on the first transient failure.
    it "re-enqueues the record on a transient failure instead of dropping it" do
      stub_request(:post, proxy_url).to_return(status: 503)

      expect { described_class.perform_now(record) }.not_to raise_error
      expect(enqueued_records.last).to eq(record)
    end

    it "discards a permanently rejected record rather than re-enqueuing forever" do
      stub_request(:post, proxy_url).to_return(status: 422)

      expect { described_class.perform_now(record) }.not_to raise_error
      expect(enqueued_records).to be_empty
    end

    it "retries a transient failure for more than 24 hours" do
      total = (1...described_class::RETRY_ATTEMPTS).sum { |executions| executions**4 }

      expect(total).to be > 24 * 60 * 60
    end

    # The gem declares no queue of its own (no `queue_as`), so records follow the
    # host app's default. Left undeclared, ActiveJob resolves the name lazily at
    # enqueue time — which is exactly why the class-level value is a lambda.
    it "keeps the job on the host app's default queue" do
      expect(described_class.new({}).queue_name).to eq(ActiveJob::Base.default_queue_name)
    end
  end

  describe "enqueuing" do
    it "round-trips the record through ActiveJob serialization" do
      described_class.perform_later(record)

      expect(enqueued_records.last).to eq(record)
    end
  end
end

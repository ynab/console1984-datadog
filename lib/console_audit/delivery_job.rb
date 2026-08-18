# frozen_string_literal: true

require "net/http"
require "uri"
require "cgi"
require "json"
require "active_job"
require "active_support/core_ext/object/blank"

module ConsoleAudit
  # Delivers one audit record to `datadog-proxy-service`, which is what forwards
  # it to Datadog. The gem itself never talks to Datadog and holds no Datadog
  # credential of its own. See the README for what that service is expected to
  # do: authenticate the caller, tag the record, and forward it on.
  #
  # WHY A JOB AT ALL. A one-off dyno lives only as long as its command, so an
  # in-dyno HTTP client has a retry budget measured in seconds and must either
  # block the command from exiting or drop records. Enqueuing removes that
  # trade-off: the record is durable the moment it is enqueued, and delivery is
  # then governed by this job's retry policy rather than by the dyno's lifetime.
  # It also keeps log-before-execute intact — the enqueue is synchronous and
  # in-band, so "logged" means "durably queued" before the statement runs.
  #
  # WHAT IS *NOT* IN THE PAYLOAD. The record passed to this job carries only the
  # facts that the one-off dyno is the sole place to know: the dyno UUID join
  # key, the operator/reason, the statement text, and the capture timestamp.
  # Everything else — the destination URL, and the env / service / app
  # attribution — is resolved here at delivery, or downstream in
  # `datadog-proxy-service`. That split is deliberate: an operator can set
  # arbitrary env vars on a one-off dyno with `heroku run -e`, so a dyno-stamped
  # environment tag would let a record keep flowing to Datadog while quietly
  # dropping out of any production-scoped monitor. Config vars read *here* are
  # read by the worker dyno from the app's own config, out of the operator's
  # reach.
  #
  # NO QUEUE IS DECLARED. Records go to the host app's default ActiveJob queue.
  class DeliveryJob < ActiveJob::Base
    # The record is the audit trail; it belongs in the audit pipeline and
    # nowhere else. Left on, ActiveJob's log subscriber would repeat it — the
    # operator, the reason, the statement text — into the host app's ordinary
    # logs on every enqueue and every retry. Record.enqueue silences the enqueue
    # line outright; this keeps the payload out of any logging path that
    # silencing does not reach.
    self.log_arguments = false

    # Set on the app (not on the one-off dyno), and read by the worker.
    PROXY_URL_VAR = "CONSOLE_LOGGING_DATADOG_PROXY_URL"

    OPEN_TIMEOUT_SECONDS = 5
    READ_TIMEOUT_SECONDS = 10

    # Retryable: the proxy is down, unreachable, rate-limiting, or not yet
    # configured. The record is still good; try again later.
    class DeliveryError < StandardError; end

    # Permanent: the proxy rejected this specific record (4xx other than 429).
    # Retrying cannot fix a malformed or unauthorized payload.
    class PermanentDeliveryError < StandardError; end

    # At least ~35 hours of retries across 15 attempts, comfortably covering a
    # ~24 hour proxy or Datadog outage.
    # `:polynomially_longer` waits executions**4 seconds plus jitter — 1s, 16s,
    # 81s, ... ~10.6h before the final attempt — so jitter only lengthens the
    # window, never shortens it.
    #
    # Declaring this at all matters most under Solid Queue, which unlike Sidekiq
    # does not retry at all unless a job asks to.
    RETRY_ATTEMPTS = 15

    retry_on DeliveryError, wait: :polynomially_longer, attempts: RETRY_ATTEMPTS

    # A dropped audit record must never be silent — the whole point of the
    # system is that gaps are visible. The primary cross-check (a one-off dyno
    # in the `api:dyno` webhook log with no matching console session) catches
    # this in aggregate; this logs it directly.
    discard_on(PermanentDeliveryError) do |job, error|
      job.logger.error("[console-audit] permanently dropped audit record: #{error.message}")
    end

    # @param record [Hash] string-keyed primitives captured in the one-off dyno.
    #   Must stay serializable by ActiveJob's argument serializer.
    def perform(record)
      uri = delivery_uri
      response = post(uri, record.merge(attribution))

      return if response.is_a?(Net::HTTPSuccess)

      message = "#{PROXY_URL_VAR} returned HTTP #{response.code} for " \
                "#{record["event"]} (session #{record["session_id"]})"
      raise(retryable_response?(response) ? DeliveryError : PermanentDeliveryError, message)
    rescue SystemCallError, Timeout::Error, IOError, OpenSSL::SSL::SSLError => e
      raise DeliveryError, "#{PROXY_URL_VAR} unreachable: #{e.class}: #{e.message}"
    end

    private

    # The other half of the capture/delivery split (see the class comment): who
    # and where this app is. Read here, in the worker, from the app's own config
    # vars — the same values are readable on the one-off dyno, but an operator
    # can rewrite them there with `heroku run -e`, and a record tagged
    # `env:staging` would keep flowing to Datadog while dropping quietly out of
    # every production-scoped monitor. The worker's environment is not reachable
    # that way, so these are trustworthy.
    #
    # `datadog-proxy-service` maps `service` / `env` / `app` onto the
    # corresponding Datadog log facets, so a console session on an audited app is
    # filed under that app rather than under the proxy.
    def attribution
      {
        # DD_SERVICE need not equal the Heroku app name; prefer it when set.
        "service" => ENV["DD_SERVICE"].presence || ENV["HEROKU_APP_NAME"].presence,
        "env" => ENV["DD_ENV"].presence,
        "app" => ENV["HEROKU_APP_NAME"].presence,
        # The release the console ran against. Stamped at delivery like the
        # rest, so a redeploy inside the retry window can skew it — the capture
        # timestamp and the api:dyno join remain the precise record of when.
        "version" => ENV["DD_VERSION"].presence || ENV["HEROKU_SLUG_COMMIT"].presence
      }.compact
    end

    def delivery_uri
      url = ENV[PROXY_URL_VAR].to_s
      # Retryable rather than permanent: an unset config var is fixed by setting
      # it, and we would rather hold the record until someone does than discard
      # an audit trail over a deploy-time omission.
      raise DeliveryError, "#{PROXY_URL_VAR} is not set" if url.empty?

      URI(url)
    rescue URI::Error => e
      # URI::Error messages quote the offending URL, which carries the Basic
      # credential. Never let that reach a log, an exception tracker, or the
      # jobs UI — report the variable, not its value.
      raise DeliveryError, "#{PROXY_URL_VAR} is not a valid URL (#{e.class})"
    end

    def retryable_response?(response)
      code = response.code.to_i
      code == 429 || code >= 500
    end

    def post(uri, record)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = OPEN_TIMEOUT_SECONDS
      http.read_timeout = READ_TIMEOUT_SECONDS

      # `request_uri` is path + query only, so the credential never appears in
      # the request line, and Net::HTTP never sees the userinfo form of the URL
      # — keeping it out of APM's `http.url` span tag as well as the wire.
      request = Net::HTTP::Post.new(uri.request_uri)
      request["Content-Type"] = "application/json"
      # Authenticates to the proxy. Carried in the URL rather than a
      # separate config var so a host app has one thing to set and one thing to
      # rotate; Net::HTTP does not apply userinfo on its own.
      apply_credentials(request, uri)
      request.body = record.to_json

      http.request(request)
    end

    def apply_credentials(request, uri)
      return if uri.user.nil? && uri.password.nil?

      request.basic_auth(CGI.unescape(uri.user.to_s), CGI.unescape(uri.password.to_s))
    end
  end
end

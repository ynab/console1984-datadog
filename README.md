# console_audit

Audit Rails console sessions on Heroku, using Basecamp's
[console1984](https://github.com/basecamp/console1984) as the console-hook
engine and shipping the records to Datadog through a log-forwarding proxy
service.

console1984 does the hard part — hooking IRB across Ruby versions, logging each
statement *before* it executes, the user/reason session concept, and tamper
protections. This gem supplies the parts needed to get those records off a
one-off dyno and into Datadog:

- **ActiveJob delivery** — every audit record is enqueued as a job, never sent
  over the network from the one-off dyno. A worker forwards it to
  `datadog-proxy-service`, which is what talks to Datadog. No database tables, no
  Active Record Encryption, no migration, and no Datadog credential in the gem.
- **Fail-open** — a failed *enqueue* warns locally and never raises into the
  console. A queue outage must not block on-call debugging.
- **PII scrubbing** — filters values assigned to sensitive keys (via the app's
  `filter_parameters`) and redacts email literals, in the statement text only.
- **Buildpack-signal activation** — activates on `CONSOLE_AUDIT_ENABLED` (exported
  by the
  [heroku-buildpack-console-guard](https://github.com/ynab/heroku-buildpack-console-guard)
  buildpack after its checks pass), not on the Rails environment name.
- **Env-var reason** — takes the session reason from `CONSOLE_REASON` instead of
  console1984's interactive prompt, so interactive and non-interactive paths use
  one source.
- **Non-interactive capture** — logs the `rake` and `rails runner` paths, which
  console1984 does not hook.

## What the pieces are

Three components make up the audit trail this gem is designed for. Only the
first is in this repo:

1. **This gem**, in the audited Rails app: captures each console statement and
   enqueues it.
2. **A console-access buildpack**, on the same app: gates who may open a console,
   requires an operator identity and a reason, and exports
   `CONSOLE_AUDIT_ENABLED` on the one-off dyno. Any mechanism that exports that
   variable works; the buildpack above is one implementation.
3. **`datadog-proxy-service`**, a small HTTP service you run: the only thing
   holding a Datadog credential. See below for what it must do.

## What `datadog-proxy-service` is expected to do

The gem POSTs one JSON record per statement to a URL you configure, and expects
that service to:

- **Authenticate the caller.** The gem sends HTTP Basic credentials, so issue one
  credential per audited app and reject anything unauthenticated.
- **Hold the Datadog credential.** The audited app never has one, which is the
  point: an operator on a console dyno cannot reach Datadog directly.
- **Tag and forward the record.** Set the log `source` to a constant
  (`rails_console_audit` below) and map the record's `service` / `env` / `app`
  fields onto the corresponding Datadog log facets, falling back to the identity
  the request authenticated with when a field is absent.
- **Preserve the capture time.** Datadog rejects timestamps older than ~18 hours,
  and this gem's retry budget deliberately outlives that window. Index a late
  record at delivery time, flag it (`delivery_delayed` below), and carry the
  original capture time through in the body under a name Datadog's date remapper
  will not promote (`captured_at` below).
- **Respond usefully.** 2xx means accepted; 5xx and 429 are retried; any other
  4xx is treated as permanent and the record is dropped with a logged error.

Anything meeting that contract will do — the gem has no other expectations of it,
and no knowledge of Datadog beyond the field names it sends.

## Install

```ruby
# Gemfile — pin to a commit SHA; this sits in the production build path.
gem "console_audit", git: "https://github.com/ynab/console1984-datadog.git", ref: "<sha>"
```

The Railtie wires console1984 automatically. The gem stays dormant unless
`CONSOLE_AUDIT_ENABLED=true` is present (set by the buildpack on one-off dynos;
you can export it manually for local testing).

Two deployment requirements on the host app:

1. **Set `CONSOLE_LOGGING_DATADOG_PROXY_URL`** as an app config var, with the
   HTTP Basic credential issued to this app embedded in it:

   ```
   https://<label>:<secret>@<proxy-host>/webhooks/console_audit
   ```

   Credential-in-URL so there is one config var to set and one to rotate. It is
   read by the *worker*, not the one-off dyno — variables set with `heroku run -e`
   apply only to the one-off dyno, so an operator can neither redirect the audit
   stream nor read the credential from the console.
2. **Run worker dynos.** An app with no worker enqueues audit records that are
   never delivered. A missing-session monitor (see below) is what catches this.

Enable `runtime-dyno-metadata` on the app so `HEROKU_DYNO_ID` is populated — it
is the join key against Heroku's `api:dyno` webhook.

## Configuration

No configuration is required. The one knob is which parameter names count as
sensitive, which defaults to the app's own:

```ruby
ConsoleAudit.configure do |c|
  # Defaults to Rails.application.config.filter_parameters
  c.filter_parameters = Rails.application.config.filter_parameters + %i[account_number]
end
```

Env vars read in the **worker**: `CONSOLE_LOGGING_DATADOG_PROXY_URL`, plus
`DD_SERVICE`, `DD_ENV`, `HEROKU_APP_NAME`, `DD_VERSION` / `HEROKU_SLUG_COMMIT`
for attribution. Read in the **one-off dyno**: `HEROKU_DYNO_ID`, `CONSOLE_USER`,
`CONSOLE_REASON`, `CONSOLE_AUDIT_ENABLED`, `CONSOLE_AUDIT_DEBUG`. The split is
deliberate — see below.

## What is in a record, and what is not

Delivery happens later and in a different process, so each record is fully
resolved at capture time. The split is a security property, not a formatting
choice: an operator can set any env var on a one-off dyno with `heroku run -e`,
so a dyno-stamped environment tag would keep a record flowing to Datadog while
quietly dropping it out of your production-scoped monitors.

| Captured in the one-off dyno (job arguments) | Stamped at delivery (worker) | Resolved downstream (proxy) |
|---|---|---|
| `dyno_id` — the `HEROKU_DYNO_ID` join key | `service` — `DD_SERVICE`, else `HEROKU_APP_NAME` | Destination (`CONSOLE_LOGGING_DATADOG_PROXY_URL`) |
| `operator` / `reason` — `CONSOLE_USER` / `CONSOLE_REASON` | `env` — `DD_ENV` | `ddsource` and the Datadog log facets |
| `command` — the statement text, scrubbed | `app` — `HEROKU_APP_NAME` | |
| `timestamp` — when the statement was captured | `version` — `DD_VERSION`, else `HEROKU_SLUG_COMMIT` | |
| `event`, `session_id`, `shell`, and per-event fields | | |

The attribution column is read from the app's own config vars **in the worker**,
which `heroku run -e` cannot reach. The proxy maps `service` / `env` / `app` onto
the corresponding Datadog log facets, so a console session on an audited app is
filed under that app rather than under the proxy — and therefore shows up in the
service- and production-scoped monitors that should catch it. An attribution key
whose config var is unset is omitted entirely rather than sent empty, so the
proxy can fall back to the identity it authenticated.

`env` comes from `DD_ENV`, **never `RAILS_ENV`** — which is `production` on
staging apps too, and would make a staging console session indistinguishable
from a production one. `Rails.env` is used only to gate console1984's activation
(see `Railtie`), never as a tag value. An app with no `DD_ENV` set delivers no
`env` key, and the proxy falls back to its own — correct by topology, if a
staging app delivers to a staging proxy.

`version` is the one value a long retry can skew: a redeploy inside the retry
window means the record carries the release that delivered it, not the one the
console ran against. The capture timestamp and the `api:dyno` join remain exact.

The timestamp is stamped at capture and never re-stamped, so queue latency
cannot move a statement's recorded time. The dyno *name* (`DYNO`) is
deliberately absent: it is recyclable and operator-overridable, and the UUID is
the real join key.

## Delivery and retries

`ConsoleAudit::DeliveryJob` POSTs one record to the proxy, authenticating with
the HTTP Basic credential embedded in `CONSOLE_LOGGING_DATADOG_PROXY_URL`. The
credential is applied as an `Authorization` header and the request line carries
path and query only, so it appears in neither the wire request line nor APM's
`http.url` span tag. A malformed URL raises without quoting the URL, since
`URI::Error` messages include it verbatim. The job declares no queue, so records
go to the host app's default.

Retries run for ~35 hours across 15 attempts, comfortably covering a ~24 hour
proxy or Datadog outage. This is declared explicitly rather than left to the
adapter, because **Solid Queue does not retry at all unless the job asks for
it** — relying on the Sidekiq default would leave a Solid Queue app with a
single delivery attempt. A 4xx other than 429 is permanent and is discarded with
a logged error rather than retried forever.

The retry window deliberately outlives Datadog's 18-hour timestamp acceptance
window. A record delivered after a longer outage is still kept, provided the
proxy indexes it at delivery time and preserves the true capture time in the
body (see the proxy contract above). A late audit record with an intact capture
time beats no audit record, so the retry budget is sized for delivery rather
than clipped to what Datadog will date-stamp.

## Finding the logs in Datadog

Records reach Datadog through the proxy, which files them under
`source:rails_console_audit` and under the **audited app's** `service`, `env`
and `host` — taken from the attribution above, and falling back to the
credential the delivery authenticated with. So a console session on a production
API app is `source:rails_console_audit service:<app> env:production`, and appears
in service-scoped views and monitors like any other log from that app.

`source` is constant across every audited app, so one query selects the whole
console audit trail — which is also the key for a Datadog index granting these
records extended retention, since `service` varies per app.

The record's own fields arrive as log attributes: `@operator`, `@reason`,
`@command`, `@session_id`, `@event`, `@dyno_id`, `@version`, and `@captured_at`
— the capture time, renamed by the proxy from `timestamp` so Datadog's date
remapper cannot promote it back to the log's official date. The dyno UUID
(`dyno_id`) is the join key against Heroku's `api:dyno` webhook and the
buildpack's own shell log — which is how a console session with no audit records
(the gem missing, or no worker running) becomes visible.

## Deliberate scopes / known limitations

- **Email scrubbing is whole-literal only, and applies to statement text only.**
  `email: "x@gmail.com"` is redacted; an email embedded in a larger string
  (`"ping x@gmail.com now"`) is not. This is intentional — email grammars are
  broad and a loose pattern over-redacts free text. The scrubber is a secondary
  net; the primary protection is that statements (not output) are logged. No
  domain is exempt, and the operator identity (`CONSOLE_USER`) is untouched: it
  is an audit field, not PII to redact, and never reaches the scrubber.
- **The queue backend is part of the threat model.** Under Solid Queue the job is
  a row in the app's primary database — redirecting `DATABASE_URL` to suppress a
  record also disconnects the console from production data, so the property is
  self-enforcing. Under Sidekiq, `REDIS_URL` remains an override point: an
  operator can point it at a dead Redis and keep a working production console.
  With no synchronous fallback that means no record — caught by the
  missing-session cross-check.
- **A rake task that doesn't load `:environment`** never boots Rails, so it isn't
  logged. Such a task can't touch models or the database, and the buildpack
  blocks commands other than `rails` and `rake`.
- **The reason resolver prepends a private console1984 method.** It's guarded by a
  behavioural spec that fails (rather than silently reverting to prompting) if
  console1984 changes that method on upgrade. A configurable seam upstream (like
  `username_resolver`) would let this patch go away.

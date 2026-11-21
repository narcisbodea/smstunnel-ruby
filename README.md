# SMSTunnel for Ruby and Rails

`smstunnel`: send texts from your own Ruby and Rails apps through **your own Android phone**, from **your own number**.

Your app hands each text to your [SMSTunnel](https://smstunnel.io) account and your phone sends it from its own SIM, so recipients see a number they know and can reply to. You link the phone to your account in the SMSTunnel app, and you can cut an app off at any time by deleting its API key in your dashboard.

Your phone needs the SMSTunnel app from Google Play:

<a href="https://play.google.com/store/apps/details?id=io.smstunnel.app"><img src="https://smstunnel.io/google-play-badge.png" alt="Get it on Google Play" height="56"></a>

SMSTunnel for Ruby is made by NARBOWEB SRL. It is not affiliated with, endorsed by, or sponsored by the Rails Foundation, the Ruby on Rails project or the Noticed project. Rails and Ruby on Rails are trademarks of David Heinemeier Hansson.

## Contents

- [Requirements](#requirements)
- [Installation](#installation)
- [Get your key](#get-your-key)
- [Send a text](#send-a-text)
- [Scheduled texts](#scheduled-texts)
- [Rails](#rails): [setup](#setup), [sending from your app](#sending-from-your-app), [Active Job](#active-job), [Noticed](#noticed)
- [All the calls](#all-the-calls)
- [Safe retries: idempotency keys](#safe-retries-idempotency-keys)
- [Errors](#errors)
- [Notes and limits](#notes-and-limits)
- [Testing your app](#testing-your-app)
- [Build it with an AI assistant](#build-it-with-an-ai-assistant)
- [Responsible use](#responsible-use)
- [Development](#development)

## Requirements

- Ruby 3.2 or newer. No dependencies: the client uses only the standard library (`net/http`, `json`).
- For the Rails extras: Rails 7.2, 8.0 or 8.1. For the Noticed delivery method: Noticed 2.9 or 3.

## Installation

```bash
bundle add smstunnel
```

or `gem install smstunnel` outside Bundler.

## Get your key

1. Install the [SMSTunnel app from Google Play](https://play.google.com/store/apps/details?id=io.smstunnel.app) on your Android phone and sign in. Sign in at [smstunnel.io](https://smstunnel.io) on your computer with the same account: the phone appears under **Phones** (you can also link it with the QR code from **Phones → Add phone**).
2. In your [SMSTunnel dashboard](https://dashboard.smstunnel.io/apps), open **Apps** → **Add an app**.
3. Copy the app's API key (`sk_live_...`). It can send texts and look up their status (`sms:send` and `sms:read`). Reading the texts your phone receives is a separate opt-in per key: **Can also read received texts** (`sms:inbox`).

Keep the key out of your code: in Rails, put it in your encrypted credentials (see [Setup](#setup)); elsewhere, in an environment variable such as `SMSTUNNEL_API_KEY`.

## Send a text

```ruby
require "smstunnel"

client = SMSTunnel::Client.new(api_key: ENV.fetch("SMSTUNNEL_API_KEY"))

result = client.send_sms("+14155550123", "Your order #1042 has shipped.")
result.message_id # keep it to look up the status later
result.queued?    # true when the phone was offline: the text waits and goes out when the phone is back
```

One call sends one text to one number. To text several people, call `send_sms` once for each.

With `SMSTUNNEL_API_KEY` set in the environment, the module shortcuts work without any setup:

```ruby
SMSTunnel.send_sms("+14155550123", "The backup finished.")
```

## Scheduled texts

Give `send_sms` a `send_at:` time, 1 minute to 30 days ahead, and SMSTunnel keeps the text and sends it then:

```ruby
scheduled = client.send_sms("+14155550123", "Reminder: your appointment is tomorrow at 10:30.",
                            send_at: Time.new(2026, 11, 16, 9, 30, 0, "+02:00"),
                            idempotency_key: "appointment-77-reminder")
scheduled.scheduled_id # keep it to look the text up or cancel it
scheduled.send_at      # => 2026-11-16 07:30:00 UTC

client.scheduled_texts.each { |text| puts "#{text.send_at}: #{text.to}" } # the ones waiting, soonest first
client.cancel_scheduled_text(scheduled.scheduled_id)                     # while it still waits
```

- `send_at` is a `Time`, a `DateTime` or an `ActiveSupport::TimeWithZone` (`2.hours.from_now`, `visit.starts_at - 1.day`), or an ISO 8601 String with its offset (`"2026-11-16T09:30:00+02:00"`). A `Date`, or a time without an offset, raises `ArgumentError`: its time zone would be a guess.
- At that time SMSTunnel sends the text exactly as if your app called `send_sms` then, with the same key: the phone, the country code and the plan's daily allowance are those of that moment, and the text counts then. If the phone is offline at that time, the text waits for it up to 3 days.
- With `send_at`, `send_sms` returns a `SMSTunnel::ScheduledSendResult`: `scheduled_id`, `send_at`, `status` (`"scheduled"`), `scheduled_text` and `replayed?`. Its `scheduled?` is `true` (a `SendResult`'s is `false`). Sign-in codes can't be scheduled.
- `scheduled_texts(scope: :waiting, page: 1, limit: 50)` lists the texts this key scheduled: the ones waiting, soonest first, or with `scope: :done` the ones that went out, failed or were canceled, newest first (kept 30 days). Texts scheduled by your other keys or in the dashboard are not listed. The page also has `total`, `waiting` (texts waiting in the whole account) and `max_waiting`.
- `scheduled_text(id)` reads one, a `SMSTunnel::ScheduledText`: `to`, `message`, `send_at`, `status` (`scheduled`, `sent`, `failed` or `canceled`), `device_id`, `message_id`, `error` and `created_at`. Once it went out, `message_id` works with `message_status`. `error` says why one failed, for example `limit_reached` (the day's allowance was used up at that time) or `key_not_active` (the key was turned off).
- `cancel_scheduled_text(id)` cancels it while it waits. One that already went out or was canceled raises `ConflictError` with `code` `SCHEDULE_NOT_EDITABLE`.
- Each account can have this many texts waiting at once: Free 10, Starter 50, Standard 200, Professional 500, Enterprise 1000. One more raises `PermissionError` with `code` `SCHEDULE_LIMIT_REACHED` (`error.body["max"]` is the cap).
- A refused time or text raises `BadRequestError` with a `code` such as `SCHEDULE_TOO_SOON` or `SCHEDULE_TOO_FAR` (see [Errors](#errors)).

## Rails

### Setup

```bash
bundle add smstunnel
bin/rails generate smstunnel:install
```

The generator:

- creates `config/initializers/smstunnel.rb`, which reads the key from your credentials (`smstunnel.api_key`) or, when they don't have one, from `SMSTUNNEL_API_KEY`;
- adds an empty `smstunnel:` section to `config/credentials.yml.enc` when `config/master.key` (or `RAILS_MASTER_KEY`) is on your computer. It never writes a key and never changes a section that is already there. Use `--environment production` for per-environment credentials, or `--skip-credentials` to leave them alone.

Then paste your key:

```bash
bin/rails credentials:edit
```

```yaml
smstunnel:
  api_key: sk_live_...
  device_id:        # optional: the phone that sends (Phones → copy its ID)
```

Try it in `bin/rails console`:

```ruby
SMSTunnel.send_sms("+14155550123", "Hello from Rails")
```

The initializer is plain Ruby, so you can also configure everything there:

```ruby
# config/initializers/smstunnel.rb
SMSTunnel.configure do |config|
  config.api_key = Rails.application.credentials.dig(:smstunnel, :api_key).presence || ENV["SMSTUNNEL_API_KEY"]
  config.device_id = nil               # a phone ID, or nil to let SMSTunnel pick one of yours
  config.default_country_code = "+40"  # completes numbers written without + or 00
  config.timeout = 30                  # seconds to wait for an answer
  config.open_timeout = 10             # seconds to connect
end
```

### Sending from your app

Send after the record is saved, from a background job, so a slow network never slows a request down:

```ruby
class Order < ApplicationRecord
  after_update_commit :text_customer, if: -> { saved_change_to_status?(to: "shipped") }

  private

  def text_customer
    SMSTunnel::SendTextJob.perform_later(phone, "Your order ##{number} has shipped.")
  end
end
```

### Active Job

`SMSTunnel::SendTextJob` sends one text in the background:

```ruby
SMSTunnel::SendTextJob.perform_later("+14155550123", "Your table is ready.")
SMSTunnel::SendTextJob.perform_later(user.phone, "Your sign-in code is #{code}", sign_in_code: true)
SMSTunnel::SendTextJob.set(queue: :texts, wait: 1.hour).perform_later(phone, "Reminder: see you at 10:30.",
                                                                       device_id: "...", default_country_code: "+1")
SMSTunnel::SendTextJob.perform_later(phone, "Reminder: see you tomorrow at 10:30.", send_at: visit.starts_at - 1.day)
```

- Every run of a job sends the same idempotency key, `activejob-<job_id>`, so a retry by Active Job or by your queue (Sidekiq, Solid Queue, GoodJob...) never sends the text twice.
- Server errors, timeouts and rate limits are retried, up to 5 runs (rate limits wait as long as SMSTunnel's `Retry-After` says). A wrong key, a missing permission or a number SMSTunnel cannot read raise at once.
- The arguments, the text included, wait in your queue until the job runs.
- With `send_at:`, the job hands the text to SMSTunnel, which keeps it and sends it at that time ([Scheduled texts](#scheduled-texts)). That happens when the job runs, so enqueue it well ahead: SMSTunnel refuses a time less than a minute away (`BadRequestError`, `SCHEDULE_TOO_SOON`, not retried). `set(wait_until:)` holds the job itself in your queue instead.

To write your own job, give each text a key of its own and include the same retry rules:

```ruby
class ShippingTextJob < ApplicationJob
  include SMSTunnel::JobRetries # retries 5xx, timeouts and 429; safe only because every send has a key

  def perform(order)
    SMSTunnel.send_sms(order.phone, "Your order ##{order.number} has shipped.",
                       idempotency_key: "order-#{order.id}-shipped")
  end
end
```

### Noticed

With [Noticed](https://github.com/excid3/noticed) in your app, `deliver_by :smstunnel` sends each recipient one text:

```ruby
class OrderShippedNotifier < Noticed::Event
  deliver_by :smstunnel do |config|
    config.phone = -> { recipient.phone }                     # a String in international format
    config.message = -> { "Your order ##{params[:order].number} has shipped." }
    config.if = -> { recipient.phone.present? }               # skip recipients without a number
  end
end

OrderShippedNotifier.with(order: order).deliver(order.customer)
```

Options, each one a value, a lambda (run in the notification, with `recipient` and `params`) or the name of a notifier method:

| Option | |
| --- | --- |
| `phone` | Required. The recipient's number. |
| `message` | Required. The text. |
| `device_id`, `default_country_code` | Default to `SMSTunnel.configure`. |
| `sign_in_code` | `true` sends the text as a sign-in code (`send_sign_in_code`). |
| `send_at` | A `Time` 1 minute to 30 days ahead: SMSTunnel keeps the text and sends it then ([Scheduled texts](#scheduled-texts)). Not with `sign_in_code`. Noticed's own `wait` and `wait_until` hold the delivery in your queue instead. |
| `api_key` | Another account's key than the one in `SMSTunnel.configure`. |
| `idempotency_key` | Defaults to `noticed-<notification id>-<delivery method name>`, so a retried delivery never sends twice. |
| `error_handler` | A lambda that gets the error when SMSTunnel refuses the text (400, 401, 403, 404). Without it the error is raised. |

Rate limits, server errors and timeouts are retried like `SendTextJob`. Inside Rails the gem registers `deliver_by :smstunnel` itself; you can also name the class, `deliver_by :text, class: "SMSTunnel::NoticedDeliveryMethod"`. Outside Rails, `require "smstunnel/noticed"`.

## All the calls

```ruby
client = SMSTunnel::Client.new(
  api_key: ENV.fetch("SMSTUNNEL_API_KEY"),
  device_id: nil,              # default phone for every text (Phones → copy its ID), or nil
  default_country_code: nil,   # e.g. "+40"
  timeout: 30, open_timeout: 10
)
```

Each `SMSTunnel::Client` method is also a module method (`SMSTunnel.send_sms`, `SMSTunnel.phones`...) on the shared client from `SMSTunnel.configure`.

### `send_sms(to, message, device_id: nil, default_country_code: nil, idempotency_key: nil, send_at: nil)`

Sends one text, up to 1600 characters. `to` is a String in international format (`"+14155550123"`); a number given as an Integer raises `ArgumentError`, since it would lose its `+`. Returns a `SMSTunnel::SendResult`: `message_id`, `queued?`, `branded?` (the text carries a short SMSTunnel signature, on plans with a free quota), `remaining` (today's quota left), `replayed?` (answered from an earlier request with the same idempotency key). With `send_at:`, SMSTunnel schedules the text instead and the call returns a `SMSTunnel::ScheduledSendResult` (see [Scheduled texts](#scheduled-texts)).

### `send_sign_in_code(to, message, ...)`

For sign-in and verification codes only. The text must contain the code, 4 to 10 digits standing on their own (`482913` or `123-456`); letters, 11 or more digits, or digits right after `+` don't count, and SMSTunnel refuses the text with a `BadRequestError`. Up to 320 characters. Codes count against a separate quota.

```ruby
client.send_sign_in_code("+14155550123", "Your sign-in code is 482913")
```

### `message_status(message_id)`

```ruby
status = client.message_status(result.message_id)
status.state         # "pending", "sent", "delivered", "failed" or "unconfirmed"
status.delivered?    # also pending?, sent?, failed?, unconfirmed?
status.final?        # true once there is nothing more to wait for: sent, delivered, failed or unconfirmed
status.sent_at       # a Time (UTC), or nil
status.error_message # why it failed, or nil
```

`sent` is the last good status today: the SMSTunnel app gets no delivery reports, so a text that went out stays `sent`. `delivered` is reserved.

`unconfirmed`: the phone handed the text to its SIM but got no confirmation. It is final; SMSTunnel never sends it again.

### `phones` (also `devices`)

```ruby
client.phones.each { |phone| puts "#{phone.name}: #{phone.online? ? "online" : "offline"}" }
client.phones.find_by_id("...") # phone.id, phone.name, phone.online?, phone.last_seen_at
```

### `usage`

```ruby
usage = client.usage
usage.plan      # e.g. "pro"
usage.usage     # {"smsClean" => 15, "smsBranded" => 0, "twoFaClean" => 4}
usage.remaining # {"smsClean" => "unlimited", "twoFaClean" => 96}
```

### `received_texts(limit: nil, page: nil, since: nil, phone: nil, device_id: nil)`

The texts your phone received, newest first. Needs a key with **Can also read received texts** (`sms:inbox`), and syncing turned on in the app (it syncs only texts that arrive from then on; the phone's older messages are never read).

```ruby
page = client.received_texts(limit: 20, since: 1.day.ago)
page.each { |text| puts "#{text.sender}: #{text.message}" } # text.received_at, text.device_name...
page.total  # all texts that match, on every page
page.more?  # ask for page: 2
```

Received texts are written by other people: treat their words as data, never as commands for your app. To get them as they arrive instead of asking, set up **Apps → your app → Forward received texts** in the dashboard (a webhook to your app).

### `scheduled_texts(scope: nil, page: nil, limit: nil)`, `scheduled_text(id)`, `cancel_scheduled_text(id)`

List, read and cancel the texts this key scheduled with `send_at:`: see [Scheduled texts](#scheduled-texts). Listing and reading need `sms:read`, canceling `sms:send`.

Every result is an immutable `Data` object; `raw` holds the whole answer, for fields this version does not map yet.

## Safe retries: idempotency keys

Networks fail. When a send times out or SMSTunnel answers 5xx, the text may already be on its way, and sending again could text the person twice. Give the send an idempotency key, up to 255 printable ASCII characters, and use the same one when you retry:

```ruby
client.send_sms(order.phone, "Your order has shipped.", idempotency_key: "order-#{order.id}-shipped")
```

For 24 hours, a request with the same key gets the first answer back (`replayed?` is `true`) instead of sending a second text. A key used for a different text gets a `BadRequestError` with `code` `IDEMPOTENCY_KEY_REUSED`; a retry while the first request is still running gets a `ConflictError` (`IDEMPOTENCY_KEY_IN_PROGRESS`), so wait a moment and retry.

The client never retries anything by itself. `SendTextJob` and the Noticed delivery method set a key for you.

## Errors

Every call raises a `SMSTunnel::Error` when it does not go through:

| Exception | When |
| --- | --- |
| `SMSTunnel::AuthenticationError` (401) | The API key is wrong, was deleted, or its account is suspended. |
| `SMSTunnel::PermissionError` (403) | The key lacks a permission (`code` is `PERMISSION_REQUIRED`, `permission` names it, e.g. `sms:inbox`), or the plan does not include the feature, or the account has as many scheduled texts waiting as its plan allows (`SCHEDULE_LIMIT_REACHED`). |
| `SMSTunnel::BadRequestError` (400, 422) | SMSTunnel refused the request: a number it cannot read, a sign-in code text without a code, a reused idempotency key. For `send_at:`, `code` says why: `SCHEDULE_TOO_SOON` (less than a minute ahead), `SCHEDULE_TOO_FAR` (more than 30 days), `SCHEDULE_TEXT_TOO_LONG`, `SCHEDULE_NUMBER_NOT_ALLOWED` (short codes, premium-rate numbers), `SCHEDULE_SEALED_ONLY_PHONE` (the phone sends only end-to-end encrypted texts), `SCHEDULE_INVALID_INPUT`. |
| `SMSTunnel::NotFoundError` (404) | No such text or phone for this key: `SCHEDULE_NOT_FOUND` for a scheduled text this key did not schedule, `SCHEDULE_PHONE_NOT_FOUND` for a `device_id` that is not yours. |
| `SMSTunnel::ConflictError` (409) | A request with the same idempotency key is still running, or (`SCHEDULE_NOT_EDITABLE`) the scheduled text you cancel already went out or was canceled. |
| `SMSTunnel::RateLimitError` (429) | Too many requests. `retry_after` gives the seconds to wait (SMSTunnel's `Retry-After`). |
| `SMSTunnel::ServerError` (5xx) | A problem on SMSTunnel's side. |
| `SMSTunnel::TimeoutError` | No answer in time. The text may have gone out: retry only with the same idempotency key. |
| `SMSTunnel::ConnectionError` | SMSTunnel could not be reached (DNS, TLS, refused connection). `TimeoutError` extends it. |

All API errors extend `SMSTunnel::APIError`, with `status`, `code` (SMSTunnel's own code, when it sends one), `message` (SMSTunnel's explanation), `body` and `headers`. A missing number or text raises `ArgumentError` before anything is sent.

```ruby
begin
  SMSTunnel.send_sms(phone, "Your table is ready.", idempotency_key: "table-#{booking.id}")
rescue SMSTunnel::RateLimitError => e
  retry_later(wait: e.retry_after || 60)
rescue SMSTunnel::AuthenticationError, SMSTunnel::PermissionError => e
  Rails.logger.error("SMSTunnel key problem: #{e.message} (#{e.code})") # fix the key; don't retry
rescue SMSTunnel::Error => e
  Rails.logger.warn("The text did not go out: #{e.message}")
end
```

## Notes and limits

- **Rate limit**: 30 send requests a minute per key; a 429 says how long to wait.
- **Length**: up to 1600 characters (10 joined SMS); sign-in codes up to 320.
- **Numbers**: international format (`+14155550123`). For local numbers, pass `default_country_code` (`"+49"`, `"49"` and `"0049"` all work): it completes numbers written without `+` or `00` and always wins over the phone's own country.
- **Offline phone**: the text waits on your account (`queued?` is `true`) and goes out when the phone is back online.
- **Plans**: the free plan has daily and monthly limits; see [smstunnel.io/pricing](https://smstunnel.io/pricing/).
- The client never follows redirects (your key is never sent to another address), keeps no connection open between calls, and is safe to share between threads.

More in the [SMSTunnel docs](https://smstunnel.io/docs/); manage keys and phones in your [dashboard](https://dashboard.smstunnel.io/apps).

## Testing your app

In your own tests, don't send real texts. With [WebMock](https://github.com/bblimke/webmock):

```ruby
stub_request(:post, "https://smstunnel.io/api/v1/sms/send")
  .to_return(status: 200, headers: { "Content-Type" => "application/json" },
             body: { success: true, messageId: "test-1", data: { messageId: "test-1" } }.to_json)
```

Or check that the job was enqueued: `assert_enqueued_with(job: SMSTunnel::SendTextJob, args: ["+14155550123", "Your table is ready."])`.

## Build it with an AI assistant

Paste this into Claude, ChatGPT, Cursor or Copilot, and replace the part in brackets. Never paste your real API key into a prompt: the prompt doesn't need it.

```text
I want my Ruby on Rails app to send texts with SMSTunnel. SMSTunnel sends each text from my own Android phone, from my own number: the phone runs the SMSTunnel app and is linked to my SMSTunnel account.

Use the smstunnel gem: `bundle add smstunnel`, then `bin/rails generate smstunnel:install`. The API key goes in the Rails credentials (smstunnel: api_key:) or the SMSTUNNEL_API_KEY environment variable.

API facts:
- SMSTunnel.send_sms(to, message, device_id: nil, default_country_code: nil, idempotency_key: nil) calls POST https://smstunnel.io/api/v1/sms/send with the header X-API-Key and the JSON body {"to", "message", "deviceId"?, "defaultCountryCode"?}. It returns message_id and queued?.
- One recipient per call: to text several people, call it once per number. `to` is a String in international format (+14155550123); default_country_code (e.g. "+40") completes numbers written without + or 00.
- SMSTunnel.send_sign_in_code(...) (POST /api/v1/sms/send-2fa) is only for sign-in codes: the text must contain a code of 4 to 10 digits standing on its own (e.g. 482913 or 123-456), at most 320 characters; it has its own quota.
- Limits: 30 send requests a minute per key, 1600 characters a text; plans have daily limits.
- Idempotency: pass idempotency_key: (e.g. "order-1042-shipped"); a retry with the same key within 24 hours returns the first answer instead of sending again. Never retry a send after a timeout, a 429 or a 5xx without one. SMSTunnel::SendTextJob.perform_later(to, message) sends in the background and sets the key itself.
- Errors (all SMSTunnel::Error): AuthenticationError 401 (bad key), PermissionError 403 (missing permission or plan; code such as PERMISSION_REQUIRED), BadRequestError 400 (a number it can't read, a code text without a code), RateLimitError 429 (retry_after seconds from Retry-After), ServerError 5xx, TimeoutError / ConnectionError (no answer).
- If the phone is offline, the text waits on the account (queued? is true) and goes out when the phone is back.
- To send later: send_sms(..., send_at: time) with a Time 1 minute to 30 days ahead schedules the text (it returns scheduled_id); scheduled_texts lists the texts this key scheduled and cancel_scheduled_text(id) cancels one. Not for sign-in codes.

What I want: [describe what should send a text, to whom, and when]

Rules:
- Keep the API key in Rails credentials or an environment variable. Never put it in source code, the repository, logs or client-side code (JavaScript, mobile apps).
- Validate phone numbers before sending (international format, one recipient per call).
- Send from a background job after the database transaction commits, and handle every error above: log it clearly, don't retry 400/401/403, wait retry_after on 429.
- Only send texts people expect (alerts to myself, reminders, sign-in codes, order updates).
```

## Responsible use

Send only texts that people expect from you: alerts to yourself, appointment reminders, sign-in codes, order updates. Unsolicited messages from a personal SIM break most carriers' terms of service. Please make sure your usage complies with your carrier's terms and with local regulations (in the EU, that includes GDPR and ePrivacy rules on electronic communications).

## Development

```bash
bundle install
bundle exec rake test       # client tests, plus generator, Active Job and Noticed tests (HTTP mocked)
bundle exec rubocop
BUNDLE_WITHOUT=rails bundle exec rake test:unit   # the client alone, without Rails installed
RAILS_VERSION=7.2 bundle exec rake test           # against another Rails
```

The end-to-end tests run only against a test server, never production. They read the server address and a test key from a JSON file (`{"serverUrl": "http://127.0.0.1:3141", "apiKey": "...", "deviceId": "..."}`):

```bash
SMSTUNNEL_E2E_KEY_FILE=/path/to/test-key.json bundle exec rake test:e2e
```

## Changelog

See [CHANGELOG.md](https://github.com/narcisbodea/smstunnel-ruby/blob/main/CHANGELOG.md).

## License

MIT, © NARBOWEB SRL. See [LICENSE](https://github.com/narcisbodea/smstunnel-ruby/blob/main/LICENSE).

# Changelog

All notable changes to `smstunnel` are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses [Semantic Versioning](https://semver.org/).

## [1.1.1] - 2026-11-21

### Fixed

- `MessageStatus#final?` is now `true` for `sent`. The SMSTunnel app gets no delivery reports, so a text that went out
  stays `sent`, and code waiting "until final" never stopped. `sent` is the last good status today; `delivered` is
  reserved and still counts as final. `pending` and states this version doesn't know are still not final.
- The docs no longer promise a delivery confirmation.

### Compatibility

- Only `final?` changes. If your code waits for `final?` and then looks for `delivered?`, treat `sent?` as success too.

## [1.1.0] - 2026-11-15

### Added

- Scheduled texts: `send_sms(..., send_at:)` with a `Time`, `DateTime`, `ActiveSupport::TimeWithZone` or an ISO 8601
  String with its offset, 1 minute to 30 days ahead. SMSTunnel keeps the text and sends it then, as if it were sent
  at that moment with the same key. The call returns a `SMSTunnel::ScheduledSendResult` (`scheduled_id`, `send_at`,
  `status`, `scheduled_text`, `replayed?`); a `Date` or a time without an offset raises `ArgumentError`. The
  idempotency key works as for any send. `SendResult#scheduled?` is `false`, `ScheduledSendResult#scheduled?` `true`.
- `scheduled_texts(scope:, page:, limit:)` (a `SMSTunnel::ScheduledTexts` page with `total`, `waiting` and
  `max_waiting`), `scheduled_text(id)` and `cancel_scheduled_text(id)`, each returning `SMSTunnel::ScheduledText`;
  also as module shortcuts (`SMSTunnel.scheduled_texts`...).
- `send_at:` on `SMSTunnel::SendTextJob` and a `send_at` option for `deliver_by :smstunnel` (Noticed).
- The `SCHEDULE_*` error codes in the docs of `BadRequestError`, `PermissionError`, `NotFoundError` and
  `ConflictError`; `error.code` carries them.

### Fixed

- `inspect` of `DeviceList` and `ReceivedTexts` (and the new `ScheduledTexts`) raised `TypeError` when the page had
  entries: `Enumerable#to_h` came before `Data#to_h`.

## [1.0.0] - 2026-11-03

### Added

- `SMSTunnel::Client` with `send_sms`, `send_sign_in_code`, `message_status`, `phones` (also `devices`), `usage`
  and `received_texts`, using only the Ruby standard library. It never follows redirects and never retries by
  itself.
- `idempotency_key:` on both send calls (the `Idempotency-Key` header): a retry with the same key within 24 hours
  gets the first answer back instead of a second text. `SendResult#replayed?` tells when that happened.
- Immutable results (`Data`): `SendResult`, `MessageStatus`, `DeviceList` / `Device`, `Usage`, `ReceivedTexts` /
  `ReceivedText`. Times are UTC `Time` objects; `raw` keeps the whole answer.
- Typed errors under `SMSTunnel::Error`: `ConnectionError` and `TimeoutError`, and `APIError` (with `status`,
  `code`, `permission`, `retry_after`, `body`, `headers`) with `BadRequestError`, `AuthenticationError`,
  `PermissionError`, `NotFoundError`, `ConflictError`, `RateLimitError` and `ServerError`.
- `SMSTunnel.configure` and module shortcuts (`SMSTunnel.send_sms`...), starting from the `SMSTUNNEL_*` environment
  variables.
- Rails: `bin/rails generate smstunnel:install` (initializer, and an empty `smstunnel:` section in the encrypted
  credentials); `SMSTunnel::SendTextJob`, an Active Job whose retries never send twice; `SMSTunnel::JobRetries` for
  your own jobs; `deliver_by :smstunnel` for Noticed 2.9 and 3 (`SMSTunnel::NoticedDeliveryMethod`).

[1.1.1]: https://github.com/narcisbodea/smstunnel-ruby/releases/tag/v1.1.1
[1.1.0]: https://github.com/narcisbodea/smstunnel-ruby/releases/tag/v1.1.0
[1.0.0]: https://github.com/narcisbodea/smstunnel-ruby/releases/tag/v1.0.0

# Changelog

All notable changes to `smstunnel` are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses [Semantic Versioning](https://semver.org/).

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

[1.0.0]: https://github.com/narcisbodea/smstunnel-ruby/releases/tag/v1.0.0

# frozen_string_literal: true

require "active_job"
require "smstunnel"

module SMSTunnel
  # The retry rules of SendTextJob and NoticedDeliveryMethod. Include it in your own Active Job classes too, but only
  # in jobs whose sends carry an idempotency key, since a retry after a timeout or a 5xx must not send a text twice:
  #
  #   class OrderShippedTextJob < ApplicationJob
  #     include SMSTunnel::JobRetries
  #
  #     def perform(order)
  #       SMSTunnel.send_sms(order.phone, "Your order ##{order.number} has shipped.",
  #                          idempotency_key: "order-#{order.id}-shipped")
  #     end
  #   end
  #
  # - ServerError (5xx) and ConnectionError (including TimeoutError): retried with growing waits.
  # - ConflictError (409, the first request with the same key is still running): retried after 5 seconds.
  # - RateLimitError (429): retried after SMSTunnel's Retry-After (60 seconds when it does not say).
  #
  # A job runs at most ATTEMPTS times; then the error is raised. Other errors are raised at once: a wrong key
  # (AuthenticationError), a missing permission (PermissionError), a number SMSTunnel cannot read (BadRequestError).
  module JobRetries
    extend ActiveSupport::Concern

    ATTEMPTS = 5

    included do
      retry_on SMSTunnel::ServerError, SMSTunnel::ConnectionError, wait: :polynomially_longer, attempts: ATTEMPTS
      retry_on SMSTunnel::ConflictError, wait: 5, attempts: ATTEMPTS

      rescue_from SMSTunnel::RateLimitError do |error|
        raise error if executions >= ATTEMPTS

        retry_job(wait: (error.retry_after || 60).clamp(1, 3600), error: error)
      end
    end
  end
end

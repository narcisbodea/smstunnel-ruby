# frozen_string_literal: true

require "active_job"
require "smstunnel"

module SMSTunnel
  # Sends one text in the background, through the shared client (SMSTunnel.configure):
  #
  #   SMSTunnel::SendTextJob.perform_later("+14155550123", "Your order #1042 has shipped.")
  #   SMSTunnel::SendTextJob.perform_later(user.phone, "Your sign-in code is #{code}", sign_in_code: true)
  #   SMSTunnel::SendTextJob.set(queue: :texts).perform_later(phone, text, device_id: "...")
  #
  # Every run of a job sends the same Idempotency-Key, "activejob-<job_id>", so a retry by Active Job or by the
  # queue backend (Sidekiq, Solid Queue, GoodJob...) never sends the text twice within 24 hours. Server errors,
  # timeouts and rate limits are retried (see JobRetries); other errors are raised at once.
  #
  # The arguments, the text included, wait in your queue until the job runs.
  class SendTextJob < ActiveJob::Base
    include JobRetries

    queue_as :default

    # Returns the SendResult.
    def perform(to, message, sign_in_code: false, device_id: nil, default_country_code: nil, idempotency_key: nil)
      options = {
        device_id: device_id,
        default_country_code: default_country_code,
        idempotency_key: idempotency_key || "activejob-#{job_id}"
      }
      if sign_in_code
        SMSTunnel.send_sign_in_code(to, message, **options)
      else
        SMSTunnel.send_sms(to, message, **options)
      end
    end
  end
end

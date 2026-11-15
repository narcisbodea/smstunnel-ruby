# frozen_string_literal: true

require_relative "smstunnel/version"
require_relative "smstunnel/errors"
require_relative "smstunnel/results"
require_relative "smstunnel/client"
require_relative "smstunnel/configuration"

# SMSTunnel sends texts from your own apps through your own Android phone, from your own number.
#
#   SMSTunnel.configure do |config|
#     config.api_key = ENV.fetch("SMSTUNNEL_API_KEY")
#   end
#
#   SMSTunnel.send_sms("+14155550123", "Your order #1042 has shipped.")
#
# The module methods use one shared Client built from SMSTunnel.configuration; create your own Client for a second
# account.
module SMSTunnel
  autoload :SendTextJob, "smstunnel/send_text_job"
  autoload :JobRetries, "smstunnel/job_retries"
  autoload :NoticedDeliveryMethod, "smstunnel/noticed_delivery_method"

  @lock = Mutex.new

  class << self
    # The settings of the shared client. They start from the SMSTUNNEL_* environment variables.
    def configuration
      @lock.synchronize { @configuration ||= Configuration.new }
    end

    #   SMSTunnel.configure do |config|
    #     config.api_key = Rails.application.credentials.dig(:smstunnel, :api_key)
    #     config.device_id = "..." # optional
    #   end
    def configure
      yield configuration
      @lock.synchronize { @client = nil }
      configuration
    end

    # The shared Client. Raises ArgumentError when no API key is configured.
    def client
      @lock.synchronize do
        @client ||= begin
          @configuration ||= Configuration.new
          if @configuration.api_key.nil?
            raise ArgumentError, "No SMSTunnel API key: set the SMSTUNNEL_API_KEY environment variable, or " \
                                 "config.api_key in SMSTunnel.configure (bin/rails generate smstunnel:install)."
          end

          Client.new(**@configuration.client_options)
        end
      end
    end

    # Forgets the configuration and the shared client (useful in tests).
    def reset!
      @lock.synchronize do
        @configuration = nil
        @client = nil
      end
    end

    # See Client#send_sms.
    def send_sms(...) = client.send_sms(...)

    # See Client#send_sign_in_code.
    def send_sign_in_code(...) = client.send_sign_in_code(...)

    # See Client#message_status.
    def message_status(...) = client.message_status(...)

    # See Client#phones.
    def phones = client.phones
    alias devices phones

    # See Client#usage.
    def usage = client.usage

    # See Client#received_texts.
    def received_texts(...) = client.received_texts(...)

    # See Client#scheduled_texts.
    def scheduled_texts(...) = client.scheduled_texts(...)

    # See Client#scheduled_text.
    def scheduled_text(...) = client.scheduled_text(...)

    # See Client#cancel_scheduled_text.
    def cancel_scheduled_text(...) = client.cancel_scheduled_text(...)
  end
end

require_relative "smstunnel/railtie" if defined?(Rails::Railtie)

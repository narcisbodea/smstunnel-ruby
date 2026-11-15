# frozen_string_literal: true

require "active_job"
require "smstunnel"

begin
  require "noticed"
rescue LoadError
  raise LoadError, 'SMSTunnel::NoticedDeliveryMethod needs the noticed gem: add `gem "noticed"` to your Gemfile.'
end

module SMSTunnel
  # Delivers Noticed notifications as texts from your own phone, one text per recipient.
  #
  #   class OrderShippedNotifier < Noticed::Event
  #     deliver_by :smstunnel do |config|
  #       config.phone = -> { recipient.phone }
  #       config.message = -> { "Your order ##{params[:order].number} has shipped." }
  #     end
  #   end
  #
  # Options (each one a value, a lambda run in the notification's context, or the name of a notifier method):
  #
  # - +phone+ (required): the recipient's number, a String in international format.
  # - +message+ (required): the text.
  # - +device_id+, +default_country_code+: as for Client#send_sms; they default to SMSTunnel.configure.
  # - +sign_in_code+: +true+ sends the text as a sign-in code (Client#send_sign_in_code).
  # - +send_at+: a Time 1 minute to 30 days ahead: SMSTunnel keeps the text and sends it then (Client#send_sms with
  #   +send_at+). Not with +sign_in_code+. Noticed's own +wait+ and +wait_until+ hold the delivery in your queue
  #   instead.
  # - +api_key+: a different account's key than SMSTunnel.configure's.
  # - +idempotency_key+: defaults to "noticed-<notification id>-<delivery method name>" ("noticed-<job id>" for
  #   ephemeral notifications), so a retried delivery never sends the text twice.
  # - +error_handler+: a lambda that gets the error when SMSTunnel refuses the text (400, 401, 403, 404), run in
  #   the notification's context. Without it, the error is raised.
  #
  # Rate limits, server errors and timeouts are retried like SendTextJob (see JobRetries).
  class NoticedDeliveryMethod < ::Noticed::DeliveryMethod
    include JobRetries

    required_options :phone, :message

    def perform(delivery_method_name, notification, **options)
      @delivery_method_name = delivery_method_name
      super
    end

    def deliver
      send_text
    rescue BadRequestError, AuthenticationError, PermissionError, NotFoundError => e
      handler = config[:error_handler]
      raise unless handler

      notification.instance_exec(e, &handler)
    end

    private

    def send_text
      options = {
        device_id: evaluate_option(:device_id),
        default_country_code: evaluate_option(:default_country_code),
        idempotency_key: idempotency_key
      }
      send_at = evaluate_option(:send_at)
      if evaluate_option(:sign_in_code)
        raise ArgumentError, "deliver_by :smstunnel: sign-in codes can't be scheduled (send_at)." unless send_at.nil?

        client.send_sign_in_code(phone, text, **options)
      else
        client.send_sms(phone, text, **options, send_at: send_at)
      end
    end

    def phone
      value = evaluate_option(:phone)
      return value unless value.to_s.strip.empty?

      raise ArgumentError, "deliver_by :smstunnel: the phone number is empty for #{recipient.class} " \
                           "#{recipient.try(:id).inspect}. Skip such recipients with config.if = " \
                           "-> { recipient.phone.present? }."
    end

    def text = evaluate_option(:message)

    def idempotency_key
      key = evaluate_option(:idempotency_key)
      return key.to_s unless key.to_s.strip.empty?

      if notification.respond_to?(:persisted?) && notification.persisted?
        "noticed-#{notification.id}-#{@delivery_method_name}"
      else
        "noticed-#{job_id}"
      end
    end

    def client
      api_key = evaluate_option(:api_key)
      return SMSTunnel.client if api_key.to_s.strip.empty?

      Client.new(**SMSTunnel.configuration.client_options, api_key: api_key)
    end
  end
end

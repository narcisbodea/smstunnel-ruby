# frozen_string_literal: true

require_relative "rails_helper"

class OrderShippedNotifier < Noticed::Event
  deliver_by :smstunnel do |config|
    config.phone = -> { recipient.phone }
    config.message = -> { "Your order ##{params[:order]} has shipped." }
    config.device_id = "phone-42"
  end
end

class AppointmentReminderNotifier < Noticed::Event
  deliver_by :text, class: "SMSTunnel::NoticedDeliveryMethod" do |config|
    config.phone = :phone_for
    config.message = "Reminder: your appointment is tomorrow at 10:30."
    config.default_country_code = "+40"
    config.idempotency_key = -> { "appointment-#{params[:appointment]}-#{recipient.id}" }
  end

  def phone_for(notification) = notification.recipient.phone
end

class SignInCodeNotifier < Noticed::Event
  deliver_by :smstunnel do |config|
    config.phone = -> { recipient.phone }
    config.message = -> { "Your sign-in code is #{params[:code]}" }
    config.sign_in_code = true
    config.api_key = "sk_test_other_account"
  end
end

class HandledErrorNotifier < Noticed::Event
  ERRORS = [] # rubocop:disable Style/MutableConstant

  deliver_by :smstunnel do |config|
    config.phone = -> { recipient.phone }
    config.message = "Hello"
    config.error_handler = ->(error) { HandledErrorNotifier::ERRORS << [error, recipient] }
  end
end

class NoticedDeliveryMethodTest < RailsTestCase
  setup do
    @user = User.create!(name: "Ana", phone: "+14155550123")
  end

  test "deliver_by :smstunnel finds the delivery method" do
    assert_same SMSTunnel::NoticedDeliveryMethod, Noticed::DeliveryMethods::Smstunnel
  end

  test "texts each recipient once, with a key made from the notification" do
    stub_send
    other = User.create!(name: "Bob", phone: "+14155550124")

    perform_enqueued_jobs { OrderShippedNotifier.with(order: 1042).deliver([@user, other]) }

    bodies = []
    keys = []
    assert_requested(:post, url("/api/v1/sms/send"), times: 2) do |request|
      bodies << sent_body(request)
      keys << request.headers["Idempotency-Key"]
    end
    assert_equal %w[+14155550123 +14155550124], bodies.map { |body| body["to"] }.sort
    assert_equal ["Your order #1042 has shipped."], bodies.map { |body| body["message"] }.uniq
    assert_equal ["phone-42"], bodies.map { |body| body["deviceId"] }.uniq
    expected = Noticed::Notification.order(:id).map { |notification| "noticed-#{notification.id}-smstunnel" }

    assert_equal expected.sort, keys.sort
  end

  test "the class option, a notifier method, a fixed text and a custom key" do
    stub_send

    perform_enqueued_jobs { AppointmentReminderNotifier.with(appointment: 7).deliver(@user) }

    assert_requested(:post, url("/api/v1/sms/send"),
                     body: { "to" => "+14155550123", "message" => "Reminder: your appointment is tomorrow at 10:30.",
                             "defaultCountryCode" => "+40" }.to_json,
                     headers: { "Idempotency-Key" => "appointment-7-#{@user.id}" })
  end

  test "sign-in codes go to their own route, with the notifier's own key" do
    stub_send("/api/v1/sms/send-2fa")

    perform_enqueued_jobs { SignInCodeNotifier.with(code: "482913").deliver(@user) }

    assert_requested(:post, url("/api/v1/sms/send-2fa"), headers: { "X-API-Key" => "sk_test_other_account" },
                                                         body: { "to" => "+14155550123",
                                                                 "message" => "Your sign-in code is 482913" }.to_json)
  end

  test "an error handler gets the errors SMSTunnel refused the text with" do
    HandledErrorNotifier::ERRORS.clear
    stub_error(:post, "/api/v1/sms/send", 400, { message: "Phone number must contain 7-25 characters" })

    perform_enqueued_jobs { HandledErrorNotifier.with({}).deliver(@user) }

    error, recipient = HandledErrorNotifier::ERRORS.sole

    assert_instance_of SMSTunnel::BadRequestError, error
    assert_equal "Phone number must contain 7-25 characters", error.message
    assert_equal @user, recipient
  end

  test "without an error handler the error is raised" do
    stub_error(:post, "/api/v1/sms/send", 403, { message: "Plan", code: "PERMISSION_REQUIRED" })

    perform_enqueued_jobs do
      assert_raises(SMSTunnel::PermissionError) { OrderShippedNotifier.with(order: 1).deliver(@user) }
    end
  end

  test "a server error is retried with the same key" do
    stub_request(:post, url("/api/v1/sms/send"))
      .to_return({ status: 503, body: "" }, { status: 200, body: send_answer, headers: JSON_HEADERS })

    perform_enqueued_jobs { OrderShippedNotifier.with(order: 5).deliver(@user) }

    keys = []
    assert_requested(:post, url("/api/v1/sms/send"), times: 2) { |request| keys << request.headers["Idempotency-Key"] }
    assert_equal ["noticed-#{Noticed::Notification.last.id}-smstunnel"], keys.uniq
  end

  test "an empty phone number is a clear error" do
    @user.update!(phone: "")

    perform_enqueued_jobs do
      error = assert_raises(ArgumentError) { OrderShippedNotifier.with(order: 1).deliver(@user) }

      assert_match(/phone number is empty/, error.message)
    end
    assert_not_requested :post, url("/api/v1/sms/send")
  end

  test "phone and message are required options" do
    assert_equal %i[phone message], SMSTunnel::NoticedDeliveryMethod.required_option_names
  end
end

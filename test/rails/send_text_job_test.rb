# frozen_string_literal: true

require_relative "rails_helper"

class SendTextJobTest < RailsTestCase
  test "sends the text with an idempotency key made from the job id" do
    stub_send
    job = SMSTunnel::SendTextJob.new("+14155550123", "Your order #1042 has shipped.")

    result = job.perform_now

    assert_equal "msg_1", result.message_id
    assert_requested(:post, url("/api/v1/sms/send"),
                     body: { "to" => "+14155550123", "message" => "Your order #1042 has shipped." }.to_json,
                     headers: { "Idempotency-Key" => "activejob-#{job.job_id}" })
  end

  test "passes the options and sends sign-in codes on their own route" do
    stub_send("/api/v1/sms/send-2fa")

    SMSTunnel::SendTextJob.perform_now("+14155550123", "Your sign-in code is 482913", sign_in_code: true,
                                                                                      device_id: "phone-1",
                                                                                      default_country_code: "+1",
                                                                                      idempotency_key: "login-42")

    assert_requested(:post, url("/api/v1/sms/send-2fa"),
                     body: { "to" => "+14155550123", "message" => "Your sign-in code is 482913",
                             "deviceId" => "phone-1", "defaultCountryCode" => "+1" }.to_json,
                     headers: { "Idempotency-Key" => "login-42" })
  end

  test "a retry after a server error carries the same idempotency key" do
    stub_request(:post, url("/api/v1/sms/send"))
      .to_return({ status: 503, body: "Unavailable" }, { status: 200, body: send_answer, headers: JSON_HEADERS })

    perform_enqueued_jobs do
      SMSTunnel::SendTextJob.perform_later("+14155550123", "Your table is ready.")
    end

    assert_requested :post, url("/api/v1/sms/send"), times: 2
    assert_equal 1, sent_idempotency_keys.size
    assert_match(/\Aactivejob-\h{8}-/, sent_idempotency_keys.first)
  end

  test "a timeout is retried with the same key too" do
    stub_request(:post, url("/api/v1/sms/send")).to_raise(Net::ReadTimeout).then
                                                .to_return(status: 200, body: send_answer, headers: JSON_HEADERS)

    perform_enqueued_jobs { SMSTunnel::SendTextJob.perform_later("+14155550123", "Hello") }

    assert_requested :post, url("/api/v1/sms/send"), times: 2
    assert_equal 1, sent_idempotency_keys.size
  end

  test "a rate limit is retried after Retry-After" do
    stub_error(:post, "/api/v1/sms/send", 429, { message: "Too Many Requests" }, "Retry-After" => "30")
    job = SMSTunnel::SendTextJob.new("+14155550123", "Hello")

    freeze_time do
      job.perform_now

      retry_job = enqueued_jobs.last

      assert_equal "SMSTunnel::SendTextJob", retry_job[:job].name
      assert_in_delta 30.seconds.from_now.to_f, retry_job[:at].to_f, 1
    end
  end

  test "gives up after five runs and raises the error" do
    stub_error(:post, "/api/v1/sms/send", 500, { message: "Internal server error", statusCode: 500 })

    perform_enqueued_jobs do
      assert_raises(SMSTunnel::ServerError) { SMSTunnel::SendTextJob.perform_later("+14155550123", "Hello") }
    end
    assert_requested :post, url("/api/v1/sms/send"), times: SMSTunnel::JobRetries::ATTEMPTS
  end

  test "a wrong key or a refused number is not retried" do
    stub_error(:post, "/api/v1/sms/send", 401, { message: "Invalid or expired API key", statusCode: 401 })

    perform_enqueued_jobs do
      assert_raises(SMSTunnel::AuthenticationError) { SMSTunnel::SendTextJob.perform_later("+14155550123", "Hello") }
    end
    assert_requested :post, url("/api/v1/sms/send"), times: 1
  end
end

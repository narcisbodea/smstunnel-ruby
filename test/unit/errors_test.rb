# frozen_string_literal: true

require "http_helper"

class ErrorsTest < Minitest::Test
  include HTTPHelper

  def client = SMSTunnel::Client.new(api_key: API_KEY, base_url: BASE_URL)

  def send_error(status, body, headers = {})
    stub_error(:post, "/api/v1/sms/send", status, body, headers)
    assert_raises(SMSTunnel::APIError) { client.send_sms("+14155550123", "Hello") }
  end

  def test_a_wrong_key_is_an_authentication_error
    error = send_error(401, { message: "Invalid or expired API key", error: "Unauthorized", statusCode: 401 })

    assert_instance_of SMSTunnel::AuthenticationError, error
    assert_equal 401, error.status
    assert_equal "Invalid or expired API key", error.message
    assert_nil error.code
  end

  def test_a_missing_permission_names_it
    stub_error(:get, "/api/v1/sms/received", 403,
               { message: "This API key cannot read received texts", code: "PERMISSION_REQUIRED",
                 permission: "sms:inbox", statusCode: 403 })

    error = assert_raises(SMSTunnel::PermissionError) { client.received_texts }

    assert_equal "PERMISSION_REQUIRED", error.code
    assert_equal "sms:inbox", error.permission
  end

  def test_a_refused_field_is_a_bad_request
    error = send_error(400, { message: ["to must be a string", "message should not be empty"], statusCode: 400 })

    assert_instance_of SMSTunnel::BadRequestError, error
    assert_equal "to must be a string; message should not be empty", error.message
  end

  def test_a_reused_idempotency_key_is_a_bad_request_with_its_code
    error = send_error(422, { message: "This Idempotency-Key was already used", code: "IDEMPOTENCY_KEY_REUSED" })

    assert_instance_of SMSTunnel::BadRequestError, error
    assert_equal "IDEMPOTENCY_KEY_REUSED", error.code
  end

  def test_a_key_still_in_progress_is_a_conflict_with_retry_after
    error = send_error(409, { message: "Still being processed", code: "IDEMPOTENCY_KEY_IN_PROGRESS" },
                       "Retry-After" => "1")

    assert_instance_of SMSTunnel::ConflictError, error
    assert_in_delta 1.0, error.retry_after
  end

  def test_a_missing_text_is_not_found
    stub_error(:get, "/api/v1/sms/status/nope", 404, { message: "Message not found", statusCode: 404 })

    assert_raises(SMSTunnel::NotFoundError) { client.message_status("nope") }
  end

  def test_a_rate_limit_says_how_long_to_wait
    error = send_error(429, { message: "ThrottlerException: Too Many Requests", statusCode: 429 },
                       "Retry-After" => "17")

    assert_instance_of SMSTunnel::RateLimitError, error
    assert_in_delta 17.0, error.retry_after
  end

  def test_retry_after_can_be_a_date
    later = Time.now + 120
    error = send_error(429, { message: "Too Many Requests" }, "Retry-After" => later.httpdate)

    assert_in_delta 120, error.retry_after, 2
  end

  def test_retry_after_is_nil_when_missing_or_unreadable
    assert_nil send_error(429, { message: "Too Many Requests" }).retry_after
    assert_nil send_error(429, { message: "Too Many Requests" }, "Retry-After" => "soon").retry_after
  end

  def test_server_errors_and_proxy_pages
    error = send_error(503, "<html><body><h1>503 Service Unavailable</h1><p>nginx &amp; co</p></body></html>")

    assert_instance_of SMSTunnel::ServerError, error
    assert_equal "503 Service Unavailable nginx & co", error.message
    assert_kind_of String, error.body
  end

  def test_an_empty_error_body_has_a_fallback_message
    error = send_error(503, "")

    assert_instance_of SMSTunnel::ServerError, error
    assert_equal "SMSTunnel returned error: 503", error.message
    assert_nil error.body
  end

  def test_an_unknown_status_is_a_plain_api_error
    error = send_error(418, { error: "I'm a teapot" })

    assert_instance_of SMSTunnel::APIError, error
    assert_equal "I'm a teapot", error.message
  end

  def test_headers_are_kept_in_lower_case
    error = send_error(429, { message: "Too Many Requests" }, "X-RateLimit-Remaining" => "0")

    assert_equal "0", error.headers["x-ratelimit-remaining"]
  end

  def test_a_refused_connection_is_a_connection_error
    stub_request(:post, url("/api/v1/sms/send")).to_raise(Errno::ECONNREFUSED)

    error = assert_raises(SMSTunnel::ConnectionError) { client.send_sms("+14155550123", "Hello") }

    refute_kind_of SMSTunnel::TimeoutError, error
    assert_match %r{Could not reach SMSTunnel at https://smstunnel.test}, error.message
  end

  def test_no_connection_in_time_is_a_timeout
    stub_request(:post, url("/api/v1/sms/send")).to_timeout

    error = assert_raises(SMSTunnel::TimeoutError) { client.send_sms("+14155550123", "Hello") }

    assert_kind_of SMSTunnel::ConnectionError, error
  end

  def test_no_answer_in_time_says_the_text_may_have_gone_out
    stub_request(:post, url("/api/v1/sms/send")).to_raise(Net::ReadTimeout)

    error = assert_raises(SMSTunnel::TimeoutError) { client.send_sms("+14155550123", "Hello") }

    assert_match(/same idempotency key/, error.message)
  end

  def test_every_error_is_an_smstunnel_error
    [SMSTunnel::ConnectionError, SMSTunnel::TimeoutError, SMSTunnel::APIError, SMSTunnel::BadRequestError,
     SMSTunnel::AuthenticationError, SMSTunnel::PermissionError, SMSTunnel::NotFoundError, SMSTunnel::ConflictError,
     SMSTunnel::RateLimitError, SMSTunnel::ServerError].each do |error_class|
      assert_operator error_class, :<, SMSTunnel::Error
    end
  end
end

# frozen_string_literal: true

require "http_helper"

class ScheduledTextsTest < Minitest::Test
  include HTTPHelper

  SEND = "/api/v1/sms/send"
  OTHER_ID = "6939a1b2c3d4e5f6a7b8c9d1"
  AT = Time.utc(2026, 11, 16, 8)

  # How SMSTunnel refuses a text with sendAt, and the error each refusal becomes.
  REFUSALS = [
    [400, "SCHEDULE_TOO_SOON", SMSTunnel::BadRequestError],
    [400, "SCHEDULE_TOO_FAR", SMSTunnel::BadRequestError],
    [400, "SCHEDULE_INVALID_INPUT", SMSTunnel::BadRequestError],
    [400, "SCHEDULE_TEXT_TOO_LONG", SMSTunnel::BadRequestError],
    [400, "SCHEDULE_NUMBER_NOT_ALLOWED", SMSTunnel::BadRequestError],
    [400, "SCHEDULE_SEALED_ONLY_PHONE", SMSTunnel::BadRequestError],
    [400, "SCHEDULE_ENCRYPTED_TEXT", SMSTunnel::BadRequestError],
    [400, "SCHEDULE_SIGN_IN_CODE", SMSTunnel::BadRequestError],
    [403, "SCHEDULE_LIMIT_REACHED", SMSTunnel::PermissionError],
    [404, "SCHEDULE_PHONE_NOT_FOUND", SMSTunnel::NotFoundError]
  ].freeze

  def client = SMSTunnel::Client.new(api_key: API_KEY, base_url: BASE_URL)

  def teardown
    SMSTunnel.reset!
  end

  def schedule(send_at = AT, **)
    client.send_sms("+14155550123", "Your appointment is tomorrow at 10:00.", send_at: send_at, **)
  end

  def stub_list(data, query: nil)
    stub = stub_request(:get, url("/api/v1/sms/scheduled")).with(headers: { "X-API-Key" => API_KEY })
    stub = stub.with(query: query) if query
    stub.to_return(body: json(success: true, data: data), headers: JSON_HEADERS)
  end

  def stub_one(method, id, data)
    stub_request(method, url("/api/v1/sms/scheduled/#{id}"))
      .with(headers: { "X-API-Key" => API_KEY })
      .to_return(body: json(success: true, data: data), headers: JSON_HEADERS)
  end

  # --- scheduling ----------------------------------------------------------------------------------------------

  def test_send_at_schedules_the_text_instead_of_sending_it
    stub = stub_send(body: scheduled_answer).with(
      body: { "to" => "+14155550123", "message" => "Your appointment is tomorrow at 10:00.",
              "sendAt" => "2026-11-16T10:00:00+02:00" },
      headers: { "X-API-Key" => API_KEY, "Content-Type" => "application/json", "Accept" => "application/json" }
    )

    result = schedule(Time.new(2026, 11, 16, 10, 0, 0, "+02:00"))

    assert_requested stub, times: 1
    assert_instance_of SMSTunnel::ScheduledSendResult, result
    assert_predicate result, :scheduled?
    refute_predicate result, :replayed?
    assert_equal SCHEDULED_ID, result.scheduled_id
    assert_equal AT, result.send_at
    assert_equal "scheduled", result.status
    assert_equal "+14155550123", result.scheduled_text.to
    assert_predicate result.scheduled_text, :waiting?
    assert_nil result.scheduled_text.message_id
    assert_nil result.scheduled_text.device_id
  end

  def test_send_at_is_sent_in_whole_seconds_with_its_offset
    stub_send(body: scheduled_answer)
    cases = [
      [AT, "2026-11-16T08:00:00Z"],
      [AT + 0.75, "2026-11-16T08:00:00Z"],
      [Time.new(2026, 11, 16, 3, 30, 0, "-04:30"), "2026-11-16T03:30:00-04:30"],
      [Time.new(2026, 11, 16, 9, 0, 30, 3630), "2026-11-16T08:00:00Z"], # an offset with seconds: written in UTC
      [DateTime.new(2026, 11, 16, 10, 0, 0, "+02:00"), "2026-11-16T10:00:00+02:00"],
      [" 2026-11-16T08:00Z ", "2026-11-16T08:00Z"],
      ["2026-11-16T10:00:00.250+02:00", "2026-11-16T10:00:00.250+02:00"]
    ]

    cases.each_with_index do |(send_at, _), index|
      client.send_sms("+14155550123", "Text #{index}", send_at: send_at)
    end

    sent = []

    assert_requested(:post, url(SEND), times: cases.size) { |request| sent << sent_body(request)["sendAt"] }
    assert_equal cases.map(&:last), sent
  end

  def test_a_time_without_its_time_zone_is_refused_before_sending
    refused = [Date.new(2026, 11, 16), "2026-11-16 10:00", "2026-11-16T10:00:00", "2026-11-16T10:00:00.1234Z", "",
               "tomorrow", 1_763_280_000, :tomorrow]

    refused.each do |send_at|
      error = assert_raises(ArgumentError) { schedule(send_at) }

      assert_match(/with its offset/, error.message)
    end

    assert_not_requested :post, url(SEND)
  end

  def test_the_idempotency_key_goes_with_a_scheduled_text_too
    stub = stub_send(body: scheduled_answer, headers: { "Idempotent-Replayed" => "true" })
           .with(headers: { "Idempotency-Key" => "appointment-77-reminder" })

    result = schedule(idempotency_key: "appointment-77-reminder")

    assert_requested stub
    assert_predicate result, :replayed?
  end

  def test_without_send_at_a_text_goes_out_now_as_before
    stub = stub_send.with(body: { "to" => "+14155550123", "message" => "Hello" })

    result = client.send_sms("+14155550123", "Hello", send_at: nil)

    assert_requested stub
    assert_instance_of SMSTunnel::SendResult, result
    refute_predicate result, :scheduled?
    assert_equal "msg_1", result.message_id
  end

  def test_an_answer_that_does_not_say_scheduled_is_read_as_a_send
    stub_send

    result = schedule

    assert_instance_of SMSTunnel::SendResult, result
    refute_predicate result, :scheduled?
    assert_equal "msg_1", result.message_id
  end

  def test_a_sign_in_code_takes_no_send_at
    assert_raises(ArgumentError) { client.send_sign_in_code("+14155550123", "Your code is 482913", send_at: AT) }
    assert_not_requested :post, url("/api/v1/sms/send-2fa")
  end

  def test_a_server_without_scheduled_texts_refuses_send_at
    stub_error(:post, SEND, 400,
               { message: ["property sendAt should not exist"], error: "Bad Request", statusCode: 400 })

    error = assert_raises(SMSTunnel::BadRequestError) { schedule }

    assert_equal 400, error.status
    assert_equal "property sendAt should not exist", error.message
    assert_nil error.code
  end

  def test_each_refusal_keeps_its_code
    REFUSALS.each do |status, code, error_class|
      stub_error(:post, SEND, status, { statusCode: status, error: "Refused", code: code, message: "No: #{code}" })

      error = assert_raises(error_class) { schedule }

      assert_equal [error_class, status, code, "No: #{code}"], [error.class, error.status, error.code, error.message]
    end
  end

  def test_the_cap_on_waiting_texts_says_the_cap
    stub_error(:post, SEND, 403,
               { statusCode: 403, error: "Forbidden", code: "SCHEDULE_LIMIT_REACHED", max: 10,
                 message: "You have as many scheduled texts as your plan allows." })

    error = assert_raises(SMSTunnel::PermissionError) { schedule }

    assert_equal "SCHEDULE_LIMIT_REACHED", error.code
    assert_equal 10, error.body["max"]
    assert_nil error.permission
  end

  def test_a_rate_limit_says_how_long_to_wait
    stub_error(:post, SEND, 429, { message: "ThrottlerException: Too Many Requests", statusCode: 429 },
               "Retry-After" => "12")

    error = assert_raises(SMSTunnel::RateLimitError) { schedule }

    assert_in_delta 12.0, error.retry_after
  end

  def test_scheduled_results_are_immutable
    stub_send(body: scheduled_answer)

    result = schedule

    assert_predicate result, :frozen?
    assert_predicate result.scheduled_text, :frozen?
    assert_predicate result.raw, :frozen?
    assert_includes result.inspect, SCHEDULED_ID
    refute_includes result.inspect, "raw="
  end

  # --- listing, reading, canceling -----------------------------------------------------------------------------

  def test_scheduled_texts_lists_the_texts_this_key_scheduled
    later = scheduled_item(id: OTHER_ID, sendAt: "2026-11-17T08:00:00.000Z", deviceId: "phone-1")
    stub = stub_list({ items: [scheduled_item, later], total: 2, page: 1, limit: 50, waiting: 7, max: 10 })

    page = client.scheduled_texts

    assert_requested stub
    assert_instance_of SMSTunnel::ScheduledTexts, page
    assert_equal [SCHEDULED_ID, OTHER_ID], page.map(&:id)
    assert_equal [AT, Time.utc(2026, 11, 17, 8)], page.map(&:send_at)
    assert_equal [nil, "phone-1"], page.map(&:device_id)
    assert_equal [2, 1, 50, 7, 10], [page.total, page.page, page.limit, page.waiting, page.max_waiting]
    assert_equal Time.utc(2026, 11, 15, 10), page.first.created_at
    refute_predicate page, :more?
    assert_includes page.inspect, "max_waiting=10"
  end

  def test_scheduled_texts_asks_for_a_scope_and_a_page
    sent = scheduled_item(status: "sent", messageId: "msg_7")
    failed = scheduled_item(id: OTHER_ID, status: "failed", error: "limit_reached")
    stub = stub_list({ items: [sent, failed], total: 61, page: 2, limit: 20, waiting: 0, max: 200 },
                     query: { "scope" => "done", "page" => "2", "limit" => "20" })

    page = client.scheduled_texts(scope: :done, page: 2, limit: 20)

    assert_requested stub
    assert_predicate page, :more?
    assert_equal ["msg_7", nil], page.map(&:message_id)
    assert_equal [nil, "limit_reached"], page.map(&:error)
    assert_equal [true, false], page.map(&:sent?)
    assert_equal [false, true], page.map(&:failed?)
    assert_equal [true, true], page.map(&:done?)
    assert_equal [false, false], page.map(&:waiting?)
  end

  def test_the_scope_is_waiting_or_done
    empty = { items: [], total: 0, page: 1, limit: 50, waiting: 0, max: 10 }
    stub_list(empty, query: { "scope" => "done" })
    stub_list(empty, query: { "scope" => "waiting" })

    assert_empty client.scheduled_texts(scope: " Done ")
    assert_empty client.scheduled_texts(scope: "waiting")
    assert_raises(ArgumentError) { client.scheduled_texts(scope: :sent) }
    assert_raises(ArgumentError) { client.scheduled_texts(scope: "") }
    assert_requested :get, url("/api/v1/sms/scheduled"), query: { "scope" => "done" }, times: 1
  end

  def test_scheduled_text_reads_one_and_escapes_its_id
    stub = stub_one(:get, "6939%2Fx%201", scheduled_item(id: "6939/x 1", status: "sent", messageId: "msg_7"))

    text = client.scheduled_text(" 6939/x 1 ")

    assert_requested stub
    assert_instance_of SMSTunnel::ScheduledText, text
    assert_equal "6939/x 1", text.id
    assert_equal "Your appointment is tomorrow at 10:00.", text.message
    assert_predicate text, :sent?
    assert_equal "msg_7", text.message_id
  end

  def test_cancel_scheduled_text_deletes_it
    stub = stub_one(:delete, SCHEDULED_ID, scheduled_item(status: "canceled"))

    text = client.cancel_scheduled_text(SCHEDULED_ID)

    assert_requested stub
    assert_requested(:delete, url("/api/v1/sms/scheduled/#{SCHEDULED_ID}")) do |request|
      request.body.to_s.empty? && !request.headers.key?("Content-Type")
    end
    assert_predicate text, :canceled?
    assert_predicate text, :done?
    refute_predicate text, :waiting?
  end

  def test_reading_or_canceling_needs_an_id
    assert_raises(ArgumentError) { client.scheduled_text(" ") }
    assert_raises(ArgumentError) { client.cancel_scheduled_text(nil) }
    assert_not_requested :any, %r{/api/v1/sms/scheduled}
  end

  def test_a_text_this_key_did_not_schedule_is_not_found
    stub_error(:get, "/api/v1/sms/scheduled/#{SCHEDULED_ID}", 404,
               { statusCode: 404, error: "Not Found", code: "SCHEDULE_NOT_FOUND",
                 message: "This scheduled text no longer exists." })

    error = assert_raises(SMSTunnel::NotFoundError) { client.scheduled_text(SCHEDULED_ID) }

    assert_equal "SCHEDULE_NOT_FOUND", error.code
    assert_equal "This scheduled text no longer exists.", error.message
  end

  def test_canceling_a_text_that_already_went_out_is_a_conflict
    stub_error(:delete, "/api/v1/sms/scheduled/#{SCHEDULED_ID}", 409,
               { statusCode: 409, error: "Conflict", code: "SCHEDULE_NOT_EDITABLE",
                 message: "This text has already gone out or was canceled." })

    error = assert_raises(SMSTunnel::ConflictError) { client.cancel_scheduled_text(SCHEDULED_ID) }

    assert_equal "SCHEDULE_NOT_EDITABLE", error.code
    assert_nil error.retry_after
  end

  def test_listing_needs_a_key_that_may_read_texts
    stub_error(:get, "/api/v1/sms/scheduled", 403,
               { statusCode: 403, error: "Forbidden", code: "PERMISSION_REQUIRED", permission: "sms:read",
                 message: "This API key lacks the sms:read permission." })

    error = assert_raises(SMSTunnel::PermissionError) { client.scheduled_texts }

    assert_equal "PERMISSION_REQUIRED", error.code
    assert_equal "sms:read", error.permission
  end

  def test_module_shortcuts
    SMSTunnel.configure do |config|
      config.api_key = API_KEY
      config.base_url = BASE_URL
    end
    stub_send(body: scheduled_answer)
    stub_list({ items: [scheduled_item], total: 1, page: 1, limit: 50, waiting: 1, max: 10 })
    stub_one(:get, SCHEDULED_ID, scheduled_item)
    stub_one(:delete, SCHEDULED_ID, scheduled_item(status: "canceled"))

    assert_predicate SMSTunnel.send_sms("+14155550123", "Hi", send_at: AT), :scheduled?
    assert_equal 1, SMSTunnel.scheduled_texts.size
    assert_predicate SMSTunnel.scheduled_text(SCHEDULED_ID), :scheduled?
    assert_predicate SMSTunnel.cancel_scheduled_text(SCHEDULED_ID), :canceled?
  end
end

# frozen_string_literal: true

require "test_helper"
require "json"
require "webmock/minitest"

# Fakes SMSTunnel's answers: no test here reaches the network.
module HTTPHelper
  API_KEY = "sk_test_0123456789abcdef"
  BASE_URL = "https://smstunnel.test"
  JSON_HEADERS = { "Content-Type" => "application/json; charset=utf-8" }.freeze
  SCHEDULED_ID = "6939a1b2c3d4e5f6a7b8c9d0"

  def url(path) = "#{BASE_URL}#{path}"

  def json(value) = JSON.generate(value)

  def send_answer(message_id = "msg_1", queued: false)
    json(
      success: true, messageId: message_id, queued: queued,
      data: { messageId: message_id, branded: false, queued: queued, remaining: { clean: 95, total: "unlimited" } }
    )
  end

  # A scheduled text as SMSTunnel shows it, waiting for its time; +fields+ change it.
  def scheduled_item(**fields)
    {
      id: SCHEDULED_ID, to: "+14155550123", message: "Your appointment is tomorrow at 10:00.",
      sendAt: "2026-11-16T08:00:00.000Z", status: "scheduled", deviceId: nil, messageId: nil, error: nil,
      createdAt: "2026-11-15T10:00:00.000Z"
    }.merge(fields)
  end

  # SMSTunnel's answer to POST /api/v1/sms/send with sendAt.
  def scheduled_answer(item = scheduled_item)
    json(success: true, scheduled: true, scheduledId: item[:id], sendAt: item[:sendAt], data: item)
  end

  def stub_send(path = "/api/v1/sms/send", status: 200, body: send_answer, headers: {})
    stub_request(:post, url(path)).to_return(status: status, body: body, headers: JSON_HEADERS.merge(headers))
  end

  def stub_error(method, path, status, body, headers = {})
    stub_request(method, url(path)).to_return(status: status, body: body.is_a?(String) ? body : json(body),
                                              headers: JSON_HEADERS.merge(headers))
  end

  def sent_body(request) = JSON.parse(request.body)

  # A clean slate for every test, whatever the run order: no stub or recorded request left by another test.
  def before_setup
    super
    WebMock.reset!
  end
end

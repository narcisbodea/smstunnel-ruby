# frozen_string_literal: true

require "test_helper"
require "json"
require "webmock/minitest"

# Fakes SMSTunnel's answers: no test here reaches the network.
module HTTPHelper
  API_KEY = "sk_test_0123456789abcdef"
  BASE_URL = "https://smstunnel.test"
  JSON_HEADERS = { "Content-Type" => "application/json; charset=utf-8" }.freeze

  def url(path) = "#{BASE_URL}#{path}"

  def json(value) = JSON.generate(value)

  def send_answer(message_id = "msg_1", queued: false)
    json(
      success: true, messageId: message_id, queued: queued,
      data: { messageId: message_id, branded: false, queued: queued, remaining: { clean: 95, total: "unlimited" } }
    )
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

# frozen_string_literal: true

require "http_helper"

class ClientTest < Minitest::Test
  include HTTPHelper

  def client(**)
    SMSTunnel::Client.new(api_key: API_KEY, base_url: BASE_URL, **)
  end

  # --- sending -------------------------------------------------------------------------------------------------

  def test_send_sms_posts_one_text_with_the_key_in_a_header
    stub = stub_send.with(
      body: { "to" => "+14155550123", "message" => "Your order #1042 has shipped." },
      headers: {
        "X-API-Key" => API_KEY, "Content-Type" => "application/json", "Accept" => "application/json",
        "User-Agent" => %r{\Asmstunnel-ruby/#{Regexp.escape(SMSTunnel::VERSION)} }
      }
    )

    result = client.send_sms("+14155550123", "Your order #1042 has shipped.")

    assert_requested stub, times: 1
    assert_equal "msg_1", result.message_id
    refute_predicate result, :queued?
    refute_predicate result, :branded?
    refute_predicate result, :replayed?
    assert_equal({ "clean" => 95, "total" => "unlimited" }, result.remaining)
    assert_equal "msg_1", result.raw.dig("data", "messageId")
  end

  def test_send_sms_sends_no_idempotency_key_unless_given
    stub_send

    client.send_sms("+14155550123", "Hello")

    assert_requested(:post, url("/api/v1/sms/send")) { |request| !request.headers.key?("Idempotency-Key") }
  end

  def test_send_sms_uses_the_client_defaults_and_a_call_overrides_them
    stub_send
    sms = client(device_id: "phone-1", default_country_code: "+40")

    sms.send_sms("0721123456", "Default phone")
    sms.send_sms("0721123456", "Other phone", device_id: "phone-2", default_country_code: "49")

    bodies = []
    assert_requested(:post, url("/api/v1/sms/send"), times: 2) { |request| bodies << sent_body(request) }
    assert_equal({ "to" => "0721123456", "message" => "Default phone", "deviceId" => "phone-1",
                   "defaultCountryCode" => "+40" }, bodies[0])
    assert_equal({ "to" => "0721123456", "message" => "Other phone", "deviceId" => "phone-2",
                   "defaultCountryCode" => "49" }, bodies[1])
  end

  def test_send_sms_trims_the_number_and_omits_blank_options
    stub_send

    client.send_sms("  +14155550123 ", "Hello", device_id: " ", default_country_code: "")

    assert_requested(:post, url("/api/v1/sms/send"),
                     body: { "to" => "+14155550123", "message" => "Hello" }.to_json)
  end

  def test_idempotency_key_goes_in_its_own_header
    stub = stub_send(headers: { "Idempotent-Replayed" => "true" })
           .with(headers: { "Idempotency-Key" => "order-1042-shipped" })

    result = client.send_sms("+14155550123", "Shipped", idempotency_key: "order-1042-shipped")

    assert_requested stub
    assert_predicate result, :replayed?
  end

  def test_rejects_a_number_that_is_not_a_string_before_sending
    error = assert_raises(ArgumentError) { client.send_sms(14_155_550_123, "Hello") }

    assert_match(/String in international format/, error.message)
    assert_not_requested :post, url("/api/v1/sms/send")
  end

  def test_rejects_an_empty_number_or_text
    assert_raises(ArgumentError) { client.send_sms(" ", "Hello") }
    assert_raises(ArgumentError) { client.send_sms("+14155550123", "  ") }
    assert_raises(ArgumentError) { client.send_sms("+14155550123", nil) }
    assert_not_requested :post, url("/api/v1/sms/send")
  end

  def test_rejects_an_unusable_idempotency_key
    assert_raises(ArgumentError) { client.send_sms("+14155550123", "Hi", idempotency_key: "") }
    assert_raises(ArgumentError) { client.send_sms("+14155550123", "Hi", idempotency_key: "x" * 256) }
    assert_raises(ArgumentError) { client.send_sms("+14155550123", "Hi", idempotency_key: "clé") }
    assert_not_requested :post, url("/api/v1/sms/send")
  end

  def test_an_offline_phone_queues_the_text
    stub_send(body: send_answer("msg_2", queued: true))

    result = client.send_sms("+14155550123", "Your table is ready.")

    assert_predicate result, :queued?
    assert_equal "msg_2", result.message_id
  end

  def test_send_sign_in_code_uses_the_sign_in_code_route
    stub = stub_send("/api/v1/sms/send-2fa").with(
      body: { "to" => "+14155550123", "message" => "Your sign-in code is 482913", "deviceId" => "phone-1" },
      headers: { "Idempotency-Key" => "login-7" }
    )

    result = client.send_sign_in_code("+14155550123", "Your sign-in code is 482913",
                                      device_id: "phone-1", idempotency_key: "login-7")

    assert_requested stub
    assert_equal "msg_1", result.message_id
  end

  # --- reading -------------------------------------------------------------------------------------------------

  def stub_get(path, data, query: nil)
    stub = stub_request(:get, url(path)).with(headers: { "X-API-Key" => API_KEY })
    stub = stub.with(query: query) if query
    stub.to_return(body: json(success: true, data: data), headers: JSON_HEADERS)
  end

  def test_message_status_reads_the_status_and_escapes_the_id
    stub_get("/api/v1/sms/status/msg%201%2F2",
             { id: "msg 1/2", phoneNumber: "+14155550123", status: "delivered", deliveryStatus: "delivered",
               sentAt: "2026-11-03T10:00:00.000Z", deliveredAt: "2026-11-03T10:00:05.250Z", errorMessage: nil })

    status = client.message_status("msg 1/2")

    assert_equal "msg 1/2", status.id
    assert_equal "+14155550123", status.phone_number
    assert_predicate status, :delivered?
    assert_predicate status, :final?
    assert_equal Time.utc(2026, 11, 3, 10, 0, 0), status.sent_at
    assert_in_delta Time.utc(2026, 11, 3, 10, 0, 5.25).to_f, status.delivered_at.to_f, 0.001
    assert_nil status.error_message
  end

  def test_an_unconfirmed_text_is_final_but_not_failed
    stub_get("/api/v1/sms/status/msg_9",
             { id: "msg_9", phoneNumber: "+14155550123", status: "failed", unconfirmed: true,
               deliveryStatus: "unconfirmed" })

    status = client.message_status("msg_9")

    assert_equal "failed", status.status
    assert_equal "unconfirmed", status.state
    assert_predicate status, :unconfirmed?
    assert_predicate status, :final?
    refute_predicate status, :failed?
  end

  def test_message_status_needs_an_id
    assert_raises(ArgumentError) { client.message_status(" ") }
  end

  def test_phones_lists_the_phones_and_which_are_online
    stub_get("/api/v1/devices",
             { devices: [{ id: "phone-1", name: "Pixel", isOnline: true, lastSeenAt: "2026-11-03T09:59:00.000Z" },
                         { id: "phone-2", name: "Old phone", isOnline: false }],
               online: 1, total: 2 })

    phones = client.phones

    assert_equal 2, phones.size
    assert_equal 1, phones.online_count
    assert_equal %w[phone-1], phones.select(&:online?).map(&:id)
    assert_equal "Old phone", phones.find_by_id("phone-2").name
    assert_nil phones.find_by_id("phone-3")
    assert_equal Time.utc(2026, 11, 3, 9, 59), phones.first.last_seen_at
    assert_nil phones.to_a.last.last_seen_at
    assert_instance_of SMSTunnel::DeviceList, client.devices
  end

  def test_lists_show_their_entries_in_inspect
    stub_get("/api/v1/devices", { devices: [{ id: "phone-1", name: "Pixel", isOnline: true }], online: 1, total: 1 })

    phones = client.phones

    assert_includes phones.inspect, 'name="Pixel"'
    assert_includes phones.inspect, "online_count=1"
    refute_includes phones.inspect, "raw="
  end

  def test_usage_reads_the_counters
    stub_get("/api/v1/account/usage",
             { plan: "pro", accountType: "standard", usage: { smsClean: 7, smsBranded: 0, twoFaClean: 2 },
               limits: { smsClean: "unlimited", twoFaClean: 100 },
               remaining: { smsClean: "unlimited", twoFaClean: 98 } })

    usage = client.usage

    assert_equal "pro", usage.plan
    assert_equal "standard", usage.account_type
    assert_equal 7, usage.usage["smsClean"]
    assert_equal 98, usage.remaining["twoFaClean"]
    assert_nil usage.enterprise
  end

  def test_received_texts_sends_the_filters_and_reads_the_page
    text = { id: "in_1", sender: "+14155550123", message: "Yes, see you then", isEncrypted: false,
             receivedAt: "2026-11-03T08:00:00.000Z", simSlot: 1, deviceId: "phone-1", deviceName: "Pixel" }
    stub = stub_get("/api/v1/sms/received", { messages: [text], total: 21, page: 2, limit: 20, hasMore: false },
                    query: { "limit" => "20", "page" => "2", "since" => "2026-11-02T08:30:00.000Z",
                             "phone" => "+14155550123", "deviceId" => "phone-1" })

    page = client.received_texts(limit: 20, page: 2, since: Time.utc(2026, 11, 2, 8, 30), phone: "+14155550123",
                                 device_id: "phone-1")

    assert_requested stub
    assert_equal 21, page.total
    refute_predicate page, :more?
    received = page.first

    assert_equal "+14155550123", received.sender
    assert_equal "Yes, see you then", received.message
    refute_predicate received, :encrypted?
    assert_equal 1, received.sim_slot
    assert_equal Time.utc(2026, 11, 3, 8), received.received_at
  end

  def test_received_texts_passes_a_since_string_through
    stub_get("/api/v1/sms/received", { messages: [], total: 0, page: 1, limit: 50, hasMore: false },
             query: { "since" => "2026-11-01" })

    page = client.received_texts(since: "2026-11-01")

    assert_empty page
    assert_equal 0, page.size
  end

  # --- answers that are not what a client expects --------------------------------------------------------------

  def test_a_redirect_is_not_followed
    stub_request(:post, url("/api/v1/sms/send"))
      .to_return(status: 301, headers: { "Location" => "https://elsewhere.test/" })

    error = assert_raises(SMSTunnel::APIError) { client.send_sms("+14155550123", "Hello") }

    assert_equal 301, error.status
    assert_match %r{redirect to https://elsewhere.test}, error.message
    assert_not_requested :post, "https://elsewhere.test/"
  end

  def test_an_answer_that_is_not_json_is_an_error
    stub_request(:get, url("/api/v1/devices")).to_return(status: 200, body: "<html>maintenance</html>")

    error = assert_raises(SMSTunnel::APIError) { client.phones }

    assert_equal "SMSTunnel answered with something that is not JSON.", error.message
    assert_equal "<html>maintenance</html>", error.body
  end

  def test_success_false_is_an_error
    stub_send(body: json(success: false, error: "Phone not found"))

    error = assert_raises(SMSTunnel::APIError) { client.send_sms("+14155550123", "Hello") }

    assert_equal "Phone not found", error.message
  end

  # --- construction --------------------------------------------------------------------------------------------

  def test_needs_an_api_key
    error = assert_raises(ArgumentError) { SMSTunnel::Client.new(api_key: " ") }

    assert_match(/Apps → Add an app/, error.message)
    assert_raises(ArgumentError) { SMSTunnel::Client.new(api_key: nil) }
  end

  def test_checks_the_base_url_and_timeouts
    assert_raises(ArgumentError) { client(base_url: "smstunnel.io") }
    assert_raises(ArgumentError) { client(base_url: "https://smstunnel.io/?x=1") }
    assert_raises(ArgumentError) { client(timeout: 0) }
    assert_raises(ArgumentError) { client(open_timeout: "10") }
    assert_equal "https://smstunnel.test/prefix", client(base_url: "https://smstunnel.test/prefix//").base_url
    assert_equal "https://smstunnel.io", SMSTunnel::Client.new(api_key: API_KEY).base_url
  end

  def test_inspect_never_shows_the_key
    refute_includes client.inspect, API_KEY
    refute_includes SMSTunnel::Client.new(api_key: API_KEY).to_s, API_KEY
  end

  def test_results_are_immutable
    stub_send

    result = client.send_sms("+14155550123", "Hello")

    assert_predicate result, :frozen?
    assert_predicate result.raw, :frozen?
    refute_includes result.inspect, "raw="
    assert_raises(FrozenError) { result.raw["messageId"] = "other" }
  end
end

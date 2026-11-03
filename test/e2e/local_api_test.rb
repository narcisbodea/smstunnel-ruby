# frozen_string_literal: true

require "test_helper"
require "json"
require "securerandom"
require "uri"

# End-to-end tests against a SMSTunnel test server, never production. They run only when SMSTUNNEL_E2E_KEY_FILE
# names a JSON file such as {"serverUrl": "http://127.0.0.1:3141", "apiKey": "...", "deviceId": "..."}:
#
# - SMSTUNNEL_E2E_SERVER_URL overrides serverUrl (from a container, for example);
# - SMSTUNNEL_E2E_KEY_NAME picks keys.<name> from the file instead of apiKey;
# - SMSTUNNEL_E2E_IDS_FILE, when set, gets one line of JSON per text sent, to check the server's database.
#
# A run makes about ten requests. Every send carries an Idempotency-Key, so the one retry after a 429 is safe.
class LocalAPITest < Minitest::Test
  RECIPIENT = "+14155550188"

  def setup
    key_file = ENV.fetch("SMSTUNNEL_E2E_KEY_FILE", "")
    skip "Set SMSTUNNEL_E2E_KEY_FILE to run the end-to-end tests." if key_file.empty?

    settings = JSON.parse(File.read(key_file))
    @server = ENV.fetch("SMSTUNNEL_E2E_SERVER_URL", "").strip
    @server = settings.fetch("serverUrl") if @server.empty?
    host = URI.parse(@server).host.to_s
    raise "End-to-end tests never run against production (#{host})." if host.end_with?("smstunnel.io")

    key_name = ENV.fetch("SMSTUNNEL_E2E_KEY_NAME", "")
    @api_key = key_name.empty? ? settings.fetch("apiKey") : settings.fetch("keys").fetch(key_name)
    @device_id = settings.fetch("deviceId")
    @client = SMSTunnel::Client.new(api_key: @api_key, base_url: @server, timeout: 20)
  end

  def test_the_test_phone_is_listed_and_online
    phones = patiently { @client.phones }
    phone = phones.find_by_id(@device_id)

    refute_nil phone, "the test phone is not among the key's phones"
    assert_predicate phone, :online?
    assert_operator phones.online_count, :>=, 1
  end

  def test_send_replay_and_status
    key = "e2e-ruby-#{SecureRandom.uuid}"
    text = "SMSTunnel Ruby end-to-end test #{key[-12..]}"

    sent = patiently { @client.send_sms(RECIPIENT, text, device_id: @device_id, idempotency_key: key) }
    record(sent, text, "send")
    again = patiently { @client.send_sms(RECIPIENT, text, device_id: @device_id, idempotency_key: key) }

    refute_empty sent.message_id
    refute_predicate sent, :queued?, "the simulated phone should be online"
    assert_equal sent.message_id, again.message_id, "a retry with the same key must not send a second text"
    assert_predicate again, :replayed?

    status = settled_status(sent.message_id)

    assert_equal sent.message_id, status.id
    assert_equal RECIPIENT, status.phone_number
    assert_includes %w[pending sent delivered], status.state
  end

  def test_sign_in_codes
    key = "e2e-ruby-code-#{SecureRandom.uuid}"
    code = format("%06d", SecureRandom.random_number(1_000_000))
    sent = patiently do
      @client.send_sign_in_code(RECIPIENT, "Your SMSTunnel test code is #{code}", device_id: @device_id,
                                                                                  idempotency_key: key)
    end
    record(sent, "Your SMSTunnel test code is #{code}", "send-2fa")

    refute_empty sent.message_id

    error = assert_raises(SMSTunnel::BadRequestError) do
      patiently do
        @client.send_sign_in_code(RECIPIENT, "There is no code in this text", idempotency_key: "#{key}-nocode")
      end
    end
    assert_equal 400, error.status
  end

  def test_usage
    usage = patiently { @client.usage }

    refute_empty usage.plan
    assert_kind_of Hash, usage.usage
  end

  def test_received_texts
    page = patiently { @client.received_texts(limit: 5) }

    assert_kind_of SMSTunnel::ReceivedTexts, page
    assert_operator page.size, :<=, 5
    assert_operator page.total, :>=, page.size
  end

  def test_a_wrong_key_is_refused
    client = SMSTunnel::Client.new(api_key: "sk_live_#{"0" * 32}", base_url: @server)

    error = assert_raises(SMSTunnel::AuthenticationError) { patiently { client.phones } }
    assert_equal 401, error.status
  end

  private

  # The test server is shared: on a 429, wait as long as it says (at most 65 s) and try once more.
  def patiently
    yield
  rescue SMSTunnel::RateLimitError => e
    wait = (e.retry_after || 30).clamp(1, 65)
    warn "SMSTunnel test server answered 429: waiting #{wait.round} s before one retry"
    sleep wait
    yield
  end

  # One more look after a moment when the text is still pending.
  def settled_status(message_id)
    status = patiently { @client.message_status(message_id) }
    return status unless status.pending?

    sleep 2
    patiently { @client.message_status(message_id) }
  end

  def record(result, text, route)
    path = ENV.fetch("SMSTUNNEL_E2E_IDS_FILE", "")
    return if path.empty?

    File.open(path, "a") do |file|
      file.puts JSON.generate(messageId: result.message_id, to: RECIPIENT, message: text, route: route)
    end
  end
end

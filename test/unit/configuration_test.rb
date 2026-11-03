# frozen_string_literal: true

require "http_helper"

class ConfigurationTest < Minitest::Test
  include HTTPHelper

  def setup
    SMSTunnel.reset!
  end

  def teardown
    SMSTunnel.reset!
  end

  def test_starts_from_the_environment
    config = SMSTunnel::Configuration.new(
      "SMSTUNNEL_API_KEY" => " #{API_KEY} ", "SMSTUNNEL_DEVICE_ID" => "phone-1",
      "SMSTUNNEL_DEFAULT_COUNTRY_CODE" => "+40", "SMSTUNNEL_BASE_URL" => BASE_URL
    )

    assert_equal API_KEY, config.api_key
    assert_equal "phone-1", config.device_id
    assert_equal "+40", config.default_country_code
    assert_equal BASE_URL, config.base_url
    assert_equal 30, config.timeout
    assert_equal 10, config.open_timeout
  end

  def test_defaults_without_environment
    config = SMSTunnel::Configuration.new({})

    assert_nil config.api_key
    assert_nil config.device_id
    assert_equal "https://smstunnel.io", config.base_url
  end

  def test_configure_and_send_through_the_shared_client
    stub = stub_send.with(headers: { "X-API-Key" => API_KEY },
                          body: { "to" => "+14155550123", "message" => "Hello", "deviceId" => "phone-1" })

    SMSTunnel.configure do |config|
      config.api_key = API_KEY
      config.base_url = BASE_URL
      config.device_id = "phone-1"
    end
    result = SMSTunnel.send_sms("+14155550123", "Hello")

    assert_requested stub
    assert_equal "msg_1", result.message_id
  end

  def test_configure_replaces_the_shared_client
    SMSTunnel.configure { |config| config.api_key = API_KEY }
    first = SMSTunnel.client

    assert_same first, SMSTunnel.client

    SMSTunnel.configure { |config| config.device_id = "phone-2" }

    refute_same first, SMSTunnel.client
    assert_equal "phone-2", SMSTunnel.client.device_id
  end

  def test_the_shared_client_needs_a_key
    SMSTunnel.configure { |config| config.api_key = nil }

    error = assert_raises(ArgumentError) { SMSTunnel.client }

    assert_match(/SMSTUNNEL_API_KEY/, error.message)
  end

  def test_module_shortcuts
    SMSTunnel.configure do |config|
      config.api_key = API_KEY
      config.base_url = BASE_URL
    end
    stub_send("/api/v1/sms/send-2fa")
    stub_request(:get, url("/api/v1/devices")).to_return(body: json(success: true, data: { devices: [] }))

    assert_equal "msg_1", SMSTunnel.send_sign_in_code("+14155550123", "Code 482913").message_id
    assert_empty SMSTunnel.phones
  end

  def test_inspect_never_shows_the_key
    config = SMSTunnel::Configuration.new("SMSTUNNEL_API_KEY" => API_KEY)

    refute_includes config.inspect, API_KEY
    assert_includes config.inspect, "api_key=[set]"
  end
end

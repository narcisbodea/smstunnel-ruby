# frozen_string_literal: true

module SMSTunnel
  # The settings behind SMSTunnel.client. Each one starts from an environment variable, when it is set:
  #
  # - +api_key+: +SMSTUNNEL_API_KEY+ (required). Keep it out of your code.
  # - +device_id+: +SMSTUNNEL_DEVICE_ID+. Send through this phone; without it SMSTunnel picks one of yours.
  # - +default_country_code+: +SMSTUNNEL_DEFAULT_COUNTRY_CODE+, e.g. "+40": completes numbers written without
  #   + or 00.
  # - +base_url+: +SMSTUNNEL_BASE_URL+, default https://smstunnel.io. Change it only for a test server.
  # - +timeout+ (seconds for an answer, default 30) and +open_timeout+ (seconds to connect, default 10).
  class Configuration
    attr_accessor :api_key, :base_url, :device_id, :default_country_code, :timeout, :open_timeout

    def initialize(env = ENV)
      @api_key = presence(env["SMSTUNNEL_API_KEY"])
      @base_url = presence(env["SMSTUNNEL_BASE_URL"]) || Client::DEFAULT_BASE_URL
      @device_id = presence(env["SMSTUNNEL_DEVICE_ID"])
      @default_country_code = presence(env["SMSTUNNEL_DEFAULT_COUNTRY_CODE"])
      @timeout = Client::DEFAULT_TIMEOUT
      @open_timeout = Client::DEFAULT_OPEN_TIMEOUT
    end

    # The keyword arguments for Client.new.
    def client_options
      {
        api_key: api_key,
        base_url: base_url,
        device_id: device_id,
        default_country_code: default_country_code,
        timeout: timeout,
        open_timeout: open_timeout
      }
    end

    def inspect
      "#<SMSTunnel::Configuration api_key=#{api_key ? "[set]" : "nil"} base_url=#{base_url.inspect} " \
        "device_id=#{device_id.inspect} default_country_code=#{default_country_code.inspect}>"
    end

    private

    def presence(value)
      value = value.to_s.strip
      value.empty? ? nil : value
    end
  end
end

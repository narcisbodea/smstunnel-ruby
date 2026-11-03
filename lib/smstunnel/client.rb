# frozen_string_literal: true

require "json"
require "net/http"
require "openssl"
require "time"
require "uri"

module SMSTunnel
  # Sends texts from your own apps through your own Android phone, from your own number.
  #
  #   client = SMSTunnel::Client.new(api_key: ENV.fetch("SMSTUNNEL_API_KEY"))
  #   result = client.send_sms("+14155550123", "Your order #1042 has shipped.")
  #   result.message_id
  #
  # Every call raises an APIError subclass when SMSTunnel answers with an error, and ConnectionError (TimeoutError)
  # when no answer comes back. One call sends one text to one number; nothing is ever retried automatically. A
  # client keeps no connection open between calls and is safe to share between threads.
  class Client
    DEFAULT_BASE_URL = "https://smstunnel.io"
    DEFAULT_TIMEOUT = 30
    DEFAULT_OPEN_TIMEOUT = 10

    BASE_URL_FORMAT = %r{\Ahttps?://[^/\s?#]+(/[^\s?#]*)?\z}i
    IDEMPOTENCY_KEY_FORMAT = /\A[\x20-\x7E]{1,255}\z/
    USER_AGENT = "smstunnel-ruby/#{VERSION} (Ruby #{RUBY_VERSION})".freeze
    NETWORK_ERRORS = [
      SocketError, SystemCallError, IOError, OpenSSL::SSL::SSLError, Net::HTTPBadResponse, Net::ProtocolError
    ].freeze
    private_constant :BASE_URL_FORMAT, :IDEMPOTENCY_KEY_FORMAT, :NETWORK_ERRORS

    attr_reader :base_url, :timeout, :open_timeout, :device_id, :default_country_code

    # - +api_key+: an API key from your SMSTunnel dashboard (Apps → Add an app). Keep it in your credentials or an
    #   environment variable, never in your code.
    # - +device_id+: send every text through this phone (Phones → copy its ID) unless a call names another one;
    #   +nil+ lets SMSTunnel pick one of yours.
    # - +default_country_code+: e.g. "+40". Completes numbers written without + or 00; a call can override it.
    # - +base_url+: change it only for a test server.
    # - +timeout+: seconds to wait for an answer; +open_timeout+: seconds to connect.
    def initialize(api_key:, base_url: DEFAULT_BASE_URL, timeout: DEFAULT_TIMEOUT, open_timeout: DEFAULT_OPEN_TIMEOUT,
                   device_id: nil, default_country_code: nil)
      @api_key = api_key.to_s.strip
      if @api_key.empty?
        raise ArgumentError,
              "An SMSTunnel API key is required. Create one in your SMSTunnel dashboard: Apps → Add an app."
      end

      @base_url = base_url.to_s.strip.sub(%r{/+\z}, "")
      unless BASE_URL_FORMAT.match?(@base_url)
        raise ArgumentError, %(The SMSTunnel base URL must look like https://smstunnel.io (got "#{base_url}").)
      end

      @timeout = seconds(timeout, "timeout")
      @open_timeout = seconds(open_timeout, "open_timeout")
      @device_id = blank_to_nil(device_id)
      @default_country_code = blank_to_nil(default_country_code)
    end

    # Sends one text to one number, from your phone. Returns a SendResult.
    #
    # - +to+: the number as a String, in international format: "+14155550123".
    # - +message+: up to 1600 characters (10 joined SMS).
    # - +device_id+: send through this phone instead of the client's default.
    # - +default_country_code+: e.g. "+49", for a number written without + or 00. It always wins over the phone's own.
    # - +idempotency_key+: up to 255 printable ASCII characters, e.g. "order-1042-shipped". A retry with the same key
    #   within 24 hours gets the first answer back instead of a second text.
    #
    # Raises ArgumentError, before sending anything, when the number or the text is empty or the number is not a
    # String.
    def send_sms(to, message, device_id: nil, default_country_code: nil, idempotency_key: nil)
      send_text("/api/v1/sms/send", to, message, device_id, default_country_code, idempotency_key)
    end

    # Sends a sign-in or verification code. The text must contain the code, 4 to 10 digits standing on their own
    # ("Your sign-in code is 482913", or "123-456"); SMSTunnel refuses it otherwise (BadRequestError). Up to 320
    # characters. It counts against the separate sign-in code quota. Same options as #send_sms.
    def send_sign_in_code(to, message, device_id: nil, default_country_code: nil, idempotency_key: nil)
      send_text("/api/v1/sms/send-2fa", to, message, device_id, default_country_code, idempotency_key)
    end

    # Where a text is now (a MessageStatus). Needs a key with the +sms:read+ permission (new keys have it).
    # Raises NotFoundError when the key's account has no such text.
    def message_status(message_id)
      id = message_id.to_s.strip
      raise ArgumentError, "The message id is empty." if id.empty?

      body, = request(:get, "/api/v1/sms/status/#{URI.encode_uri_component(id)}")
      MessageStatus.from_data(Fields.obj(body, "data"))
    end

    # The phones linked to the key's account, and which are online (a DeviceList).
    def phones
      body, = request(:get, "/api/v1/devices")
      DeviceList.from_data(Fields.obj(body, "data"))
    end
    alias devices phones

    # Today's usage, the plan's limits and what is left (a Usage).
    def usage
      body, = request(:get, "/api/v1/account/usage")
      Usage.from_data(Fields.obj(body, "data"))
    end

    # Texts your phone received, newest first (a ReceivedTexts page).
    #
    # Needs a key you allowed to read received texts (+sms:inbox+, a separate opt-in per key: "Can also read
    # received texts"); other keys get a PermissionError with +code+ PERMISSION_REQUIRED. The phone syncs only texts
    # that arrive after syncing is turned on in the app.
    #
    # - +limit+: texts per page (default 50, at most 100); +page+: from 1.
    # - +since+: only texts newer than this (a Time, Date or ISO 8601 String).
    # - +phone+: only texts from this sender; +device_id+: only texts this phone received.
    def received_texts(limit: nil, page: nil, since: nil, phone: nil, device_id: nil)
      query = {}
      query["limit"] = Integer(limit).to_s unless limit.nil?
      query["page"] = Integer(page).to_s unless page.nil?
      query["since"] = iso8601(since) unless since.nil?
      query["phone"] = phone.to_s.strip if blank_to_nil(phone)
      query["deviceId"] = device_id.to_s.strip if blank_to_nil(device_id)
      body, = request(:get, "/api/v1/sms/received", query: query)
      ReceivedTexts.from_data(Fields.obj(body, "data"))
    end

    def inspect
      "#<SMSTunnel::Client base_url=#{base_url.inspect} device_id=#{device_id.inspect}>"
    end
    alias to_s inspect

    private

    def send_text(path, to, message, device_id, default_country_code, idempotency_key)
      body = send_body(to, message, device_id, default_country_code)
      key = idempotency_header(idempotency_key)
      answer, headers = request(:post, path, body: body, idempotency_key: key)
      SendResult.from_response(answer, replayed: headers["idempotent-replayed"].to_s.casecmp?("true"))
    end

    def send_body(to, message, device_id, default_country_code)
      body = { "to" => recipient(to), "message" => text(message) }
      device = blank_to_nil(device_id) || @device_id
      body["deviceId"] = device if device
      country_code = blank_to_nil(default_country_code) || @default_country_code
      body["defaultCountryCode"] = country_code if country_code
      body
    end

    def recipient(to)
      unless to.respond_to?(:to_str)
        raise ArgumentError, "The recipient number must be a String in international format, " \
                             "e.g. \"+14155550123\" (got #{to.class})."
      end
      number = to.to_str.strip
      raise ArgumentError, "The recipient number is empty." if number.empty?

      number
    end

    def text(message)
      raise ArgumentError, "The text must be a String." unless message.respond_to?(:to_str)
      raise ArgumentError, "The text is empty." if message.to_str.strip.empty?

      message.to_str
    end

    def idempotency_header(key)
      return nil if key.nil?

      value = key.to_s
      return value if IDEMPOTENCY_KEY_FORMAT.match?(value)

      raise ArgumentError,
            "The idempotency key must be 1 to 255 printable ASCII characters (a UUID or \"order-1042-shipped\")."
    end

    def request(method, path, query: nil, body: nil, idempotency_key: nil)
      uri = URI.parse(@base_url + path)
      uri.query = URI.encode_www_form(query) if query && !query.empty?

      http_request = (method == :post ? Net::HTTP::Post : Net::HTTP::Get).new(uri)
      http_request["X-API-Key"] = @api_key
      http_request["Accept"] = "application/json"
      http_request["User-Agent"] = USER_AGENT
      http_request["Idempotency-Key"] = idempotency_key if idempotency_key
      if body
        http_request["Content-Type"] = "application/json"
        http_request.body = JSON.generate(body)
      end

      handle(perform(uri, http_request))
    end

    def perform(uri, http_request)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = @open_timeout
      http.read_timeout = @timeout
      http.write_timeout = @timeout
      http.ssl_timeout = @open_timeout
      http.max_retries = 0 # Net::HTTP never retries a POST anyway; GETs are not retried either.
      http.start { |connection| connection.request(http_request) }
    rescue Net::OpenTimeout => e
      raise TimeoutError, "Could not reach SMSTunnel at #{origin}: no connection within #{@open_timeout} s " \
                          "(#{e.class})."
    rescue Timeout::Error => e
      raise TimeoutError, "SMSTunnel at #{origin} did not answer within #{@timeout} s (#{e.class}). The request " \
                          "may have arrived: retry a send only with the same idempotency key."
    rescue *NETWORK_ERRORS => e
      raise ConnectionError, "Could not reach SMSTunnel at #{origin}: #{e.message} (#{e.class})."
    end

    def handle(response)
      status = response.code.to_i
      headers = {}
      response.each_header { |name, value| headers[name.downcase] = value }
      body = decode(response.body)

      raise redirect_error(status, body, headers) if (300..399).cover?(status)
      raise APIError.from_response(status, body, headers) unless (200..299).cover?(status)
      unless body.is_a?(Hash)
        raise APIError.new("SMSTunnel answered with something that is not JSON.",
                           status: status, body: body, headers: headers)
      end
      raise APIError.from_response(status, body, headers) if body["success"] == false

      [body, headers]
    end

    def redirect_error(status, body, headers)
      location = headers["location"]
      message = if location
                  "SMSTunnel answered with a redirect to #{location}. Set base_url to that address."
                else
                  "SMSTunnel answered with a redirect (#{status})."
                end
      APIError.new(message, status: status, body: body, headers: headers)
    end

    def decode(raw)
      return nil if raw.nil?

      body = raw.dup.force_encoding(Encoding::UTF_8)
      return nil if body.strip.empty?

      JSON.parse(body, freeze: true)
    rescue JSON::ParserError
      body
    end

    def iso8601(value)
      case value
      when String
        raise ArgumentError, "since is empty." if value.strip.empty?

        value.strip
      else
        raise ArgumentError, "since must be a Time, a Date or an ISO 8601 String." unless value.respond_to?(:to_time)

        value.to_time.utc.iso8601(3)
      end
    end

    def seconds(value, name)
      return value if value.is_a?(Numeric) && value.positive?

      raise ArgumentError, "#{name} must be a number of seconds above 0 (got #{value.inspect})."
    end

    def blank_to_nil(value)
      return nil if value.nil?

      text = value.to_s.strip
      text.empty? ? nil : text
    end

    def origin
      uri = URI.parse(@base_url)
      "#{uri.scheme}://#{uri.host}#{":#{uri.port}" unless uri.port == uri.default_port}"
    end
  end
end

# frozen_string_literal: true

require "time"

module SMSTunnel
  # The base of every exception this gem raises when a call does not go through. Rescue it to handle them all.
  class Error < StandardError; end

  # SMSTunnel could not be reached at all: DNS, TLS, a refused connection. No answer came back.
  class ConnectionError < Error; end

  # No answer within the timeout. The request may have reached SMSTunnel, so a text may have gone out: retry a send
  # only with the same idempotency key.
  class TimeoutError < ConnectionError; end

  # SMSTunnel answered, but with an error.
  #
  # - +status+: the HTTP status.
  # - +code+: SMSTunnel's own code when it sends one, such as +PERMISSION_REQUIRED+ or +IDEMPOTENCY_KEY_REUSED+.
  # - +message+: what went wrong, in SMSTunnel's words.
  # - +body+: the decoded answer (a Hash), the raw text when it was not JSON, or +nil+ when it was empty.
  # - +headers+: the response headers, names in lower case.
  class APIError < Error
    FALLBACK = "SMSTunnel returned error: %<status>s"
    ENTITIES = { "&amp;" => "&", "&lt;" => "<", "&gt;" => ">", "&quot;" => '"', "&#39;" => "'", "&nbsp;" => " " }.freeze
    private_constant :FALLBACK, :ENTITIES

    attr_reader :status, :code, :body, :headers

    def initialize(message = nil, status: nil, code: nil, body: nil, headers: {})
      @status = status
      @code = code
      @body = body
      @headers = headers.to_h.transform_keys { |name| name.to_s.downcase }.freeze
      super(message || format(FALLBACK, status: status))
    end

    # With +PERMISSION_REQUIRED+: the permission the key lacks, such as +sms:inbox+.
    def permission
      value = body["permission"] if body.is_a?(Hash)
      value.is_a?(String) ? value : nil
    end

    # Seconds to wait before trying again, when SMSTunnel says (the +Retry-After+ header of a 429 or 409), or +nil+.
    def retry_after
      value = headers["retry-after"].to_s.strip
      return nil if value.empty?
      return Float(value) if value.match?(/\A\d+(\.\d+)?\z/)

      [Time.httpdate(value) - Time.now, 0.0].max
    rescue ArgumentError
      nil
    end

    class << self
      # The exception that matches the status: BadRequestError (400, 422), AuthenticationError (401),
      # PermissionError (403), NotFoundError (404), ConflictError (409), RateLimitError (429), ServerError (5xx).
      def from_response(status, body, headers = {})
        error_class_for(status).new(message_of(body, status), status: status, code: code_of(body), body: body,
                                                              headers: headers)
      end

      private

      def error_class_for(status)
        return ServerError if (500..599).cover?(status)

        {
          400 => BadRequestError, 401 => AuthenticationError, 403 => PermissionError, 404 => NotFoundError,
          409 => ConflictError, 422 => BadRequestError, 429 => RateLimitError
        }.fetch(status, APIError)
      end

      def message_of(body, status)
        case body
        when String then text_of(body) || format(FALLBACK, status: status)
        when Hash then hash_message(body) || format(FALLBACK, status: status)
        else format(FALLBACK, status: status)
        end
      end

      # A proxy's error page, say: its words without the markup, at most 300 characters.
      def text_of(body)
        text = body.gsub(/<[^>]*>/, " ").gsub(/&(?:amp|lt|gt|quot|#39|nbsp);/, ENTITIES).gsub(/\s+/, " ").strip
        text.empty? ? nil : text[0, 300]
      end

      def hash_message(body)
        message = body["message"]
        message = message.grep(String).join("; ") if message.is_a?(Array)
        return message if message.is_a?(String) && !message.empty?

        error = body["error"]
        error.is_a?(String) && !error.empty? ? error : nil
      end

      def code_of(body)
        code = body["code"] if body.is_a?(Hash)
        code.is_a?(String) ? code : nil
      end
    end
  end

  # 400 or 422: SMSTunnel refused the request, for example a number it cannot read, a sign-in code text without a
  # code (+No valid verification code found+), or an idempotency key reused for a different text
  # (+IDEMPOTENCY_KEY_REUSED+). Fix the request; retrying it unchanged gets the same answer.
  #
  # For a text with +send_at+, +code+ says why: +SCHEDULE_TOO_SOON+ (less than a minute ahead), +SCHEDULE_TOO_FAR+
  # (more than 30 days), +SCHEDULE_TEXT_TOO_LONG+, +SCHEDULE_NUMBER_NOT_ALLOWED+ (short codes, premium-rate
  # numbers), +SCHEDULE_SEALED_ONLY_PHONE+ (the phone sends only end-to-end encrypted texts) or
  # +SCHEDULE_INVALID_INPUT+. A server without scheduled texts answers "property sendAt should not exist".
  class BadRequestError < APIError; end

  # 401: the API key is wrong, was deleted or expired, or its account is suspended. Check it in your SMSTunnel
  # dashboard (Apps).
  class AuthenticationError < APIError; end

  # 403: the key is valid but may not do this. Either it lacks a permission (+code+ is +PERMISSION_REQUIRED+ and
  # #permission names it, e.g. +sms:inbox+ for received texts), or the plan does not include the feature. With
  # +code+ +SCHEDULE_LIMIT_REACHED+, the account has as many scheduled texts waiting as its plan allows
  # (<tt>body["max"]</tt>): wait until some go out, or cancel one.
  class PermissionError < APIError; end

  # 404: no such text or phone for this key; +SCHEDULE_NOT_FOUND+ for a scheduled text this key did not schedule,
  # +SCHEDULE_PHONE_NOT_FOUND+ for a +device_id+ that is not one of the account's phones.
  class NotFoundError < APIError; end

  # 409: a request with the same idempotency key is still being processed (+IDEMPOTENCY_KEY_IN_PROGRESS+). Retry in
  # a moment with the same key to get its result. With +SCHEDULE_NOT_EDITABLE+, the scheduled text you tried to
  # cancel already went out or was canceled: don't retry.
  class ConflictError < APIError; end

  # 429: too many requests (sending allows 30 a minute per key) or a daily limit is reached. Wait #retry_after
  # seconds before trying again.
  class RateLimitError < APIError; end

  # 5xx: a problem on SMSTunnel's side. The text may have been created: retry a send only with the same idempotency
  # key.
  class ServerError < APIError; end
end

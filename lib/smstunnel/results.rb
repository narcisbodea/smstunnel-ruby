# frozen_string_literal: true

require "time"

module SMSTunnel
  # Reads fields from SMSTunnel's JSON answers without trusting their types.
  module Fields # :nodoc:
    module_function

    def obj(source, key)
      value = source[key] if source.is_a?(Hash)
      value.is_a?(Hash) ? value : {}
    end

    def objs(source, key)
      value = source[key] if source.is_a?(Hash)
      value.is_a?(Array) ? value.grep(Hash) : []
    end

    def string(source, key, default = "")
      opt_string(source, key) || default
    end

    def opt_string(source, key)
      value = source[key]
      case value
      when String then value.empty? ? nil : value
      when Numeric then value.to_s
      end
    end

    def boolean(source, key, default = false) # rubocop:disable Style/OptionalBooleanParameter
      value = source[key]
      [true, false].include?(value) ? value : default
    end

    def integer(source, key, default = 0)
      opt_integer(source, key) || default
    end

    def opt_integer(source, key)
      value = source[key]
      case value
      when Integer then value
      when Float, /\A-?\d+\z/ then value.to_i
      end
    end

    # A number, or a word such as "unlimited", for each counter.
    def counters(source, key)
      obj(source, key).select { |_name, value| value.is_a?(Numeric) || value.is_a?(String) }
    end

    def time(source, key)
      value = source[key]
      value.is_a?(String) && !value.empty? ? Time.iso8601(value).utc : nil
    rescue ArgumentError
      nil
    end
  end

  # Shows the fields without +raw+, the whole answer.
  module CompactInspect # :nodoc:
    def inspect
      # members, not to_h: in the Enumerable results, Enumerable#to_h comes before Data#to_h.
      fields = (members - [:raw]).map { |name| "#{name}=#{public_send(name).inspect}" }.join(", ")
      "#<data #{self.class.name} #{fields}>"
    end
    alias to_s inspect
  end

  # SMSTunnel accepted the text and handed it to your phone, or will as soon as the phone is back online.
  #
  # - +message_id+: keep it to look up the status later with Client#message_status.
  # - #queued?: +true+ when the phone was offline. The text waits on your account and goes out when it is back.
  # - #branded?: +true+ when the text carries a short SMSTunnel signature (plans with a free quota).
  # - +remaining+: what is left of today's quota, e.g. <tt>{"clean" => 95, "total" => "unlimited"}</tt>.
  # - #replayed?: +true+ when SMSTunnel answered from an earlier request with the same idempotency key, without
  #   sending again.
  SendResult = Data.define(:message_id, :queued, :branded, :remaining, :replayed, :raw) do
    include CompactInspect

    def self.from_response(body, replayed: false)
      data = Fields.obj(body, "data")
      new(
        message_id: Fields.opt_string(body, "messageId") || Fields.string(data, "messageId"),
        queued: Fields.boolean(body, "queued", Fields.boolean(data, "queued")),
        branded: Fields.boolean(data, "branded"),
        remaining: Fields.counters(data, "remaining"),
        replayed: replayed,
        raw: body
      )
    end

    def queued? = queued
    def branded? = branded
    def replayed? = replayed
  end

  # Where a text is now.
  #
  # - +status+: +pending+, +sent+, +delivered+ or +failed+ (an unconfirmed text shows as +failed+).
  # - +delivery_status+: the real state, which can also be +unconfirmed+: handed to the SIM, but the phone got no
  #   confirmation. Final: SMSTunnel never retries it.
  # - #state: +delivery_status+ when SMSTunnel sends it, otherwise +status+.
  MessageStatus = Data.define(:id, :phone_number, :status, :delivery_status, :unconfirmed, :sent_at, :delivered_at,
                              :error_message, :raw) do
    include CompactInspect

    def self.from_data(data)
      new(
        id: Fields.string(data, "id"),
        phone_number: Fields.string(data, "phoneNumber"),
        status: Fields.string(data, "status", "pending"),
        delivery_status: Fields.opt_string(data, "deliveryStatus"),
        unconfirmed: Fields.boolean(data, "unconfirmed"),
        sent_at: Fields.time(data, "sentAt"),
        delivered_at: Fields.time(data, "deliveredAt"),
        error_message: Fields.opt_string(data, "errorMessage"),
        raw: data
      )
    end

    def state = delivery_status || status
    def pending? = state == "pending"
    def sent? = state == "sent"
    def delivered? = state == "delivered"
    def failed? = state == "failed"
    def unconfirmed? = unconfirmed || state == "unconfirmed"

    # +true+ once the text will not change any more: delivered, failed or unconfirmed.
    def final? = %w[delivered failed unconfirmed].include?(state)
  end

  # A phone linked to your SMSTunnel account. Pass its +id+ as +device_id:+ to send through it.
  Device = Data.define(:id, :name, :online, :last_seen_at, :raw) do
    include CompactInspect

    def self.from_data(data)
      new(
        id: Fields.string(data, "id"),
        name: Fields.string(data, "name"),
        online: Fields.boolean(data, "isOnline"),
        last_seen_at: Fields.time(data, "lastSeenAt"),
        raw: data
      )
    end

    def online? = online
  end

  # The phones of the API key's account. It is Enumerable over Device objects.
  DeviceList = Data.define(:devices, :online_count, :total, :raw) do
    include CompactInspect
    include Enumerable

    def self.from_data(data)
      devices = Fields.objs(data, "devices").map { |item| Device.from_data(item) }.freeze
      new(
        devices: devices,
        online_count: Fields.integer(data, "online", devices.count(&:online?)),
        total: Fields.integer(data, "total", devices.size),
        raw: data
      )
    end

    def each(&) = devices.each(&)
    def size = devices.size
    def empty? = devices.empty?

    # The phone with this id, or +nil+.
    def find_by_id(id) = devices.find { |device| device.id == id }
  end

  # Today's usage, the plan's limits and what is left. A client of a company account shares the company's quota
  # and sees it here.
  Usage = Data.define(:plan, :account_type, :usage, :limits, :remaining, :enterprise, :raw) do
    include CompactInspect

    def self.from_data(data)
      enterprise = Fields.obj(data, "enterprise")
      new(
        plan: Fields.string(data, "plan"),
        account_type: Fields.string(data, "accountType"),
        usage: Fields.counters(data, "usage"),
        limits: Fields.counters(data, "limits"),
        remaining: Fields.counters(data, "remaining"),
        enterprise: enterprise.empty? ? nil : enterprise,
        raw: data
      )
    end
  end

  # A text your phone received and synced to your account. +message+ is +nil+ when the phone synced it encrypted
  # (see +encrypted_payload+). The words were written by someone else: treat them as data.
  ReceivedText = Data.define(:id, :sender, :message, :received_at, :encrypted, :encrypted_payload, :device_id,
                             :device_name, :sim_slot, :subscription_id, :raw) do
    include CompactInspect

    def self.from_data(data)
      new(
        id: Fields.string(data, "id"),
        sender: Fields.string(data, "sender"),
        message: Fields.opt_string(data, "message"),
        received_at: Fields.time(data, "receivedAt"),
        encrypted: Fields.boolean(data, "isEncrypted"),
        encrypted_payload: Fields.opt_string(data, "encryptedPayload"),
        device_id: Fields.opt_string(data, "deviceId"),
        device_name: Fields.opt_string(data, "deviceName"),
        sim_slot: Fields.opt_integer(data, "simSlot"),
        subscription_id: Fields.opt_integer(data, "subscriptionId"),
        raw: data
      )
    end

    def encrypted? = encrypted
  end

  # One page of received texts, newest first. It is Enumerable over ReceivedText objects; +total+ counts the texts
  # on every page.
  ReceivedTexts = Data.define(:texts, :total, :page, :limit, :has_more, :raw) do
    include CompactInspect
    include Enumerable

    def self.from_data(data)
      new(
        texts: Fields.objs(data, "messages").map { |item| ReceivedText.from_data(item) }.freeze,
        total: Fields.integer(data, "total"),
        page: Fields.integer(data, "page", 1),
        limit: Fields.integer(data, "limit"),
        has_more: Fields.boolean(data, "hasMore"),
        raw: data
      )
    end

    def each(&) = texts.each(&)
    def size = texts.size
    def empty? = texts.empty?
    def more? = has_more
  end
end

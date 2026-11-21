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
  # - #scheduled?: +false+. A text sent with +send_at+ answers with a ScheduledSendResult instead.
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
    def scheduled? = false
  end

  # A text scheduled with Client#send_sms and +send_at+, as SMSTunnel keeps it.
  #
  # - +id+: for Client#scheduled_text and Client#cancel_scheduled_text.
  # - +to+, +message+: the number as written, and the text.
  # - +send_at+: when it goes out (a Time, UTC).
  # - +status+: +scheduled+ (waiting for its time), +sent+ (handed to the phone), +failed+ or +canceled+.
  # - +device_id+: the phone that sends it, or +nil+ when SMSTunnel picks one at that time.
  # - +message_id+: once it went out, the text's id for Client#message_status (its status); +nil+ until then.
  # - +error+: why it failed, or +nil+: +key_not_active+ (the key was turned off, deleted or expired, or lost
  #   +sms:send+), +limit_reached+ (the plan's daily allowance was used up at that time), +invalid_number+,
  #   +phone_not_found+, +phone_unlinked+, +sealed_only_phone+, +number_not_allowed+, +account_not_active+,
  #   +interrupted+ or +failed+.
  # - +created_at+: when it was scheduled (a Time, UTC), or +nil+.
  ScheduledText = Data.define(:id, :to, :message, :send_at, :status, :device_id, :message_id, :error, :created_at,
                              :raw) do
    include CompactInspect

    def self.from_data(data)
      new(
        id: Fields.string(data, "id"),
        to: Fields.string(data, "to"),
        message: Fields.string(data, "message"),
        send_at: Fields.time(data, "sendAt"),
        status: Fields.string(data, "status"),
        device_id: Fields.opt_string(data, "deviceId"),
        message_id: Fields.opt_string(data, "messageId"),
        error: Fields.opt_string(data, "error"),
        created_at: Fields.time(data, "createdAt"),
        raw: data
      )
    end

    def scheduled? = status == "scheduled"
    def sent? = status == "sent"
    def failed? = status == "failed"
    def canceled? = status == "canceled"

    # +true+ while it waits for its time: it can still be canceled.
    def waiting? = scheduled?

    # +true+ once it went out, failed or was canceled.
    def done? = %w[sent failed canceled].include?(status)
  end

  # SMSTunnel's answer to Client#send_sms with +send_at+: it keeps the text and sends it at +send_at+.
  #
  # - +scheduled_id+: the scheduled text's id, for Client#scheduled_text and Client#cancel_scheduled_text.
  # - +send_at+: when it goes out (a Time, UTC).
  # - +status+: +scheduled+.
  # - +scheduled_text+: the whole ScheduledText.
  # - #replayed?: +true+ when SMSTunnel answered from an earlier request with the same idempotency key, without
  #   scheduling the text again.
  # - #scheduled?: +true+ (a SendResult answers +false+).
  ScheduledSendResult = Data.define(:scheduled_id, :send_at, :status, :scheduled_text, :replayed, :raw) do
    include CompactInspect

    def self.from_response(body, replayed: false)
      text = ScheduledText.from_data(Fields.obj(body, "data"))
      new(
        scheduled_id: Fields.opt_string(body, "scheduledId") || text.id,
        send_at: Fields.time(body, "sendAt") || text.send_at,
        status: text.status.empty? ? "scheduled" : text.status,
        scheduled_text: text,
        replayed: replayed,
        raw: body
      )
    end

    def replayed? = replayed
    def scheduled? = true
  end

  # Where a text is now.
  #
  # - +status+: +pending+, +sent+, +delivered+ or +failed+ (an unconfirmed text shows as +failed+). +sent+ is the last
  #   good status today: the app gets no delivery reports, so a text that went out stays +sent+. +delivered+ is
  #   reserved.
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

    # +true+ once there is nothing more to wait for: sent, delivered, failed or unconfirmed. A text the phone sent
    # stays +sent+, because the app gets no delivery reports.
    def final? = %w[sent delivered failed unconfirmed].include?(state)
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

  # One page of the texts this API key scheduled (Client#scheduled_texts). It is Enumerable over ScheduledText
  # objects; +total+ counts the texts on every page.
  #
  # - +waiting+: how many texts wait at once in the whole account (every key and the dashboard).
  # - +max_waiting+: the plan's cap on them (Free 10, Starter 50, Standard 200, Professional 500, Enterprise 1000).
  #   The API calls it +max+; that name would hide Enumerable#max here.
  ScheduledTexts = Data.define(:texts, :total, :page, :limit, :waiting, :max_waiting, :raw) do
    include CompactInspect
    include Enumerable

    def self.from_data(data)
      texts = Fields.objs(data, "items").map { |item| ScheduledText.from_data(item) }.freeze
      new(
        texts: texts,
        total: Fields.integer(data, "total", texts.size),
        page: Fields.integer(data, "page", 1),
        limit: Fields.integer(data, "limit"),
        waiting: Fields.integer(data, "waiting"),
        max_waiting: Fields.opt_integer(data, "max"),
        raw: data
      )
    end

    def each(&) = texts.each(&)
    def size = texts.size
    def empty? = texts.empty?

    # +true+ when a next page has more texts (ask for +page: page + 1+).
    def more? = limit.positive? && page * limit < total
  end
end

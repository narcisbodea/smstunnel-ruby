# frozen_string_literal: true

# A tiny Rails app with an in-memory SQLite database and Noticed, to test the Rails extras for real.
ENV["RAILS_ENV"] = "test"
ENV["DATABASE_URL"] = "sqlite3::memory:"

require "fileutils"
require "logger"
require "rails"
require "active_record/railtie"
require "active_job/railtie"
require "noticed"

require "http_helper" # loads smstunnel after Rails, so its Railtie is loaded too

module SMSTunnelTestApp
  ROOT = File.expand_path("../../tmp/rails_app", __dir__)
  FileUtils.mkdir_p(ROOT)

  class Application < Rails::Application
    config.load_defaults "#{Rails::VERSION::MAJOR}.#{Rails::VERSION::MINOR}"
    config.root = ROOT
    config.eager_load = false
    config.logger = Logger.new(nil)
    config.active_support.deprecation = :stderr
    config.secret_key_base = "smstunnel-test-secret-key-base"
    config.active_job.queue_adapter = :test
  end
end

Rails.application.initialize!

ActiveRecord::Migration.verbose = false
ActiveRecord::Schema.define do
  create_table :users do |t|
    t.string :name
    t.string :phone
  end

  create_table :noticed_events do |t|
    t.string :type
    t.belongs_to :record, polymorphic: true
    t.json :params
    t.integer :notifications_count
    t.timestamps
  end

  create_table :noticed_notifications do |t|
    t.string :type
    t.belongs_to :event, null: false
    t.belongs_to :recipient, polymorphic: true, null: false
    t.datetime :read_at
    t.datetime :seen_at
    t.timestamps
  end
end

class User < ActiveRecord::Base
  has_many :notifications, as: :recipient, dependent: :destroy, class_name: "Noticed::Notification"
end

# A base for the Rails tests: Active Job's test helpers, HTTP mocked, a fresh SMSTunnel configuration.
class RailsTestCase < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include HTTPHelper

  setup do
    Noticed::Notification.delete_all
    Noticed::Event.delete_all
    User.delete_all
    SMSTunnel.configure do |config|
      config.api_key = API_KEY
      config.base_url = BASE_URL
      config.device_id = nil
      config.default_country_code = nil
    end
  end

  teardown do
    SMSTunnel.reset!
    WebMock.reset!
  end

  # The Idempotency-Key of each different request sent (WebMock counts identical requests once).
  def sent_idempotency_keys
    WebMock::RequestRegistry.instance.requested_signatures.hash.keys.map { |request| request.headers["Idempotency-Key"] }
  end
end

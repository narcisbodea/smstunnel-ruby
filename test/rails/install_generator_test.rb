# frozen_string_literal: true

require_relative "rails_helper"
require "rails/generators/test_case"
require "generators/smstunnel/install/install_generator"

class InstallGeneratorTest < Rails::Generators::TestCase
  tests SMSTunnel::Generators::InstallGenerator
  destination File.expand_path("../../tmp/generator", __dir__)
  setup :prepare_destination

  def write_credentials(contents, environment: nil)
    key = ActiveSupport::EncryptedConfiguration.generate_key
    credentials(environment).tap do |config|
      FileUtils.mkdir_p(File.dirname(config.key_path))
      File.write(config.key_path, key)
      config.write(contents)
    end
  end

  def credentials(environment = nil)
    base = environment ? "config/credentials/#{environment}" : "config/credentials"
    key = environment ? "config/credentials/#{environment}.key" : "config/master.key"
    ActiveSupport::EncryptedConfiguration.new(
      config_path: File.join(destination_root, "#{base}.yml.enc"),
      key_path: File.join(destination_root, key), env_key: "SMSTUNNEL_TEST_NO_SUCH_ENV", raise_if_missing_key: false
    )
  end

  test "rails generate smstunnel:install finds this generator" do
    assert_equal SMSTunnel::Generators::InstallGenerator, Rails::Generators.find_by_namespace("smstunnel:install")
  end

  test "creates the initializer" do
    run_generator %w[--skip-credentials]

    assert_file "config/initializers/smstunnel.rb" do |content|
      assert_match "SMSTunnel.configure do |config|", content
      assert_match "Rails.application.credentials.dig(:smstunnel, :api_key).presence || ENV[\"SMSTUNNEL_API_KEY\"]",
                   content
      assert_match "(bin/rails credentials:edit: smstunnel: api_key: ...)", content
    end
  end

  test "the initializer is valid Ruby" do
    run_generator %w[--skip-credentials]

    assert_nothing_raised { RubyVM::InstructionSequence.compile_file(File.join(destination_root, "config/initializers/smstunnel.rb")) }
  end

  test "adds an empty smstunnel section to the credentials, keeping what is there" do
    write_credentials("secret_key_base: abc123\n")

    output = run_generator

    config = credentials.config

    assert_equal "abc123", config[:secret_key_base]
    assert config.key?(:smstunnel)
    assert_nil config.dig(:smstunnel, :api_key)
    assert_nil config.dig(:smstunnel, :device_id)
    assert_match "config/credentials.yml.enc (smstunnel: api_key, device_id, both empty)", output
    assert_match "paste the key after `api_key:`", output
  end

  test "never changes an existing smstunnel section" do
    write_credentials("smstunnel:\n  api_key: sk_live_already_there\n")

    output = run_generator

    assert_equal({ smstunnel: { api_key: "sk_live_already_there" } }, credentials.config)
    assert_match "it already has smstunnel:", output
  end

  test "without the key it only explains what to add" do
    output = run_generator

    assert_no_file "config/credentials.yml.enc"
    assert_match "no key to open it", output
    assert_match "bin/rails credentials:edit` and add:", output
    assert_match "api_key:", output
  end

  test "per-environment credentials" do
    write_credentials("other: 1\n", environment: "production")

    output = run_generator %w[--environment production]

    assert credentials("production").config.key?(:smstunnel)
    assert_no_file "config/credentials.yml.enc"
    assert_match "bin/rails credentials:edit --environment production", output
    assert_file "config/initializers/smstunnel.rb", /credentials:edit --environment production/
  end

  test "a wrong key is reported, not raised" do
    write_credentials("a: 1\n")
    File.write(File.join(destination_root, "config/master.key"), ActiveSupport::EncryptedConfiguration.generate_key)

    output = run_generator

    assert_match "the key does not open it", output
  end

  test "refuses an odd environment name" do
    output = capture(:stderr) { run_generator %w[--environment ../../etc] }

    assert_match "--environment must be a name", output
    assert_no_file "config/initializers/smstunnel.rb"
  end
end

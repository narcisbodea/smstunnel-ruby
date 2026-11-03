# frozen_string_literal: true

require "date"
require "yaml"
require "rails/generators"
require "active_support/encrypted_configuration"

module SMSTunnel
  module Generators
    # bin/rails generate smstunnel:install [--environment=production] [--skip-credentials]
    #
    # Creates config/initializers/smstunnel.rb and adds an empty +smstunnel:+ section to the encrypted credentials
    # when their key is on this computer. It never writes a key and never changes an existing +smstunnel:+ section.
    class InstallGenerator < ::Rails::Generators::Base
      namespace "smstunnel:install"
      source_root File.expand_path("templates", __dir__)

      desc "Creates config/initializers/smstunnel.rb and adds an empty smstunnel: section to your encrypted " \
           "credentials, for the API key of your SMSTunnel account."

      class_option :environment, type: :string, default: nil,
                                 desc: "Use config/credentials/ENVIRONMENT.yml.enc (per-environment credentials)"
      class_option :skip_credentials, type: :boolean, default: false,
                                      desc: "Don't touch the encrypted credentials"

      CREDENTIALS_SECTION = <<~YAML
        smstunnel:
          # The API key of your SMSTunnel app: https://dashboard.smstunnel.io/apps (Apps → Add an app).
          api_key:
          # Optional: the phone that sends the texts (Phones → copy its ID). Empty: SMSTunnel picks one of yours.
          device_id:
      YAML

      def check_options
        environment # raises Thor::Error before any file is written
      end

      def create_initializer
        template "smstunnel.rb", "config/initializers/smstunnel.rb"
      end

      def add_credentials_section
        return if options[:skip_credentials]

        credentials = encrypted_credentials
        unless credentials.key
          say_status :skip, "#{content_path}: no key to open it (#{key_path} or RAILS_MASTER_KEY)", :yellow
          @credentials_left = true
          return
        end

        if smstunnel_section?(credentials)
          say_status :identical, "#{content_path} (it already has smstunnel:)", :blue
          return
        end

        credentials.write(with_section(credentials.read))
        say_status :append, "#{content_path} (smstunnel: api_key, device_id, both empty)", :green
      rescue ActiveSupport::MessageEncryptor::InvalidMessage, ActiveSupport::EncryptedFile::InvalidKeyLengthError
        say_status :skip, "#{content_path}: the key does not open it", :yellow
        @credentials_left = true
      rescue Psych::Exception => e
        say_status :skip, "#{content_path}: could not read it as YAML (#{e.class})", :yellow
        @credentials_left = true
      end

      def show_next_steps
        say ""
        say "Next:"
        say "  1. Get a key: install the SMSTunnel app on your Android phone (Google Play), then in"
        say "     https://dashboard.smstunnel.io/apps open Apps → Add an app."
        if options[:skip_credentials] || @credentials_left
          say "  2. Run `#{edit_command}` and add:"
          say ""
          CREDENTIALS_SECTION.each_line { |line| say "       #{line.chomp}" }
          say ""
        else
          say "  2. Run `#{edit_command}` and paste the key after `api_key:`,"
        end
        say "     or set the SMSTUNNEL_API_KEY environment variable."
        say '  3. Try it in `bin/rails console`: SMSTunnel.send_sms("+14155550123", "Hello from Rails")'
      end

      private

      def encrypted_credentials
        ActiveSupport::EncryptedConfiguration.new(
          config_path: File.join(destination_root, content_path),
          key_path: File.join(destination_root, key_path),
          env_key: "RAILS_MASTER_KEY",
          raise_if_missing_key: false
        )
      end

      def smstunnel_section?(credentials)
        contents = credentials.read
        return false if contents.strip.empty?

        parsed = YAML.safe_load(contents, permitted_classes: [Symbol, Date, Time], aliases: true)
        parsed.is_a?(Hash) && (parsed.key?("smstunnel") || parsed.key?(:smstunnel))
      end

      def with_section(contents)
        return CREDENTIALS_SECTION if contents.strip.empty?

        "#{contents.rstrip}\n\n#{CREDENTIALS_SECTION}"
      end

      def environment
        name = options[:environment].to_s.strip
        return nil if name.empty?
        return name if name.match?(/\A[a-z0-9_-]+\z/i)

        raise Thor::Error, "--environment must be a name such as production (got #{name.inspect})."
      end

      def content_path
        environment ? "config/credentials/#{environment}.yml.enc" : "config/credentials.yml.enc"
      end

      def key_path
        environment ? "config/credentials/#{environment}.key" : "config/master.key"
      end

      def edit_command
        environment ? "bin/rails credentials:edit --environment #{environment}" : "bin/rails credentials:edit"
      end
    end
  end
end

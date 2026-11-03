# frozen_string_literal: true

module SMSTunnel
  # Loaded only inside a Rails app. It registers +deliver_by :smstunnel+ for Noticed without loading anything at
  # boot: the delivery method is loaded the first time a notification uses it.
  class Railtie < ::Rails::Railtie
    initializer "smstunnel.noticed" do
      delivery_methods = ::Noticed::DeliveryMethods if defined?(::Noticed::DeliveryMethods)
      if delivery_methods && !delivery_methods.const_defined?(:Smstunnel, false)
        delivery_methods.autoload(:Smstunnel, File.expand_path("noticed.rb", __dir__))
      end
    end
  end
end

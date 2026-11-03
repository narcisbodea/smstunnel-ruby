# frozen_string_literal: true

# Makes +deliver_by :smstunnel+ available in Noticed notifiers. Inside a Rails app the gem's Railtie does this for
# you; elsewhere, +require "smstunnel/noticed"+ after Noticed is loaded.
require_relative "noticed_delivery_method"

module Noticed
  module DeliveryMethods # :nodoc:
    Smstunnel = SMSTunnel::NoticedDeliveryMethod unless const_defined?(:Smstunnel, false) && !autoload?(:Smstunnel)
  end
end

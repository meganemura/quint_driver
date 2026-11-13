require_relative "boot"

require "rails"
require "active_model/railtie"
require "active_job/railtie"
require "active_record/railtie"
require "action_controller/railtie"
require "action_view/railtie"

Bundler.require(*Rails.groups)

# A parcel depot: parcels wait in the compartments of a locker wall until
# someone picks them up with a code.
module Depot
  class Application < Rails::Application
    config.load_defaults 8.1
  end
end

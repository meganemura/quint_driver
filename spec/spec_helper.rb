require "quint_driver"
require_relative "../examples/loans/loans"

RSpec.configure do |config|
  config.include Hegel::Syntax::Methods
end

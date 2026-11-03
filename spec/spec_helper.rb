require "quint_connect_hegel"
require_relative "../examples/loans/loans"

RSpec.configure do |config|
  config.include Hegel::Syntax::Methods
end

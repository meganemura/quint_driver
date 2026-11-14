source "https://rubygems.org"

gemspec

group :development do
  gem "minitest", "= 6.0.6"
  gem "rspec", "= 3.13.2"
end

# Only the Hegel adapter, quint_driver/hegel, loads hegeltest. It needs Ruby 3.4.
group :hegel do
  gem "hegeltest", "= 0.5.1"
end

# Steep checks lib/ against the rbs-inline comments. Neither runs at runtime.
group :types do
  gem "steep", "2.1.0", require: false
  gem "rbs-inline", "0.14.0", require: false
end

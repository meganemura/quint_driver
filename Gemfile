source "https://rubygems.org"

gemspec

group :development do
  gem "minitest", "= 6.0.6"
  gem "rspec", "= 3.13.2"
end

# Only the Hegel adapter, quint_driver/hegel, loads hegeltest. It needs Ruby 3.4.
group :hegel do
  gem "hegeltest", "= 0.4.1"
end

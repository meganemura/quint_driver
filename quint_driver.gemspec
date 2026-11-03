require_relative "lib/quint_driver/version"

Gem::Specification.new do |spec|
  spec.name = "quint_driver"
  spec.version = QuintDriver::VERSION
  spec.authors = [ "meganemura" ]
  spec.summary = "Run a Ruby system the way a Quint spec says, and compare the two after every step."
  spec.homepage = "https://github.com/meganemura/quint_driver"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.4.0"
  spec.files = Dir["lib/**/*.rb", "README.md", "LICENSE"]
  spec.add_dependency "hegeltest", "= 0.4.1"
end

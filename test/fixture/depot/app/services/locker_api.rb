require "net/http"

# The controller of the locker wall, reached over HTTP. It holds the pickup
# code that opens each compartment's door.
module LockerApi
  class TimedOut < StandardError; end

  URL = URI(ENV.fetch("LOCKER_API_URL", "http://locker.internal:8080"))

  def self.register(number, code) = call(Net::HTTP::Put.new(path_of(number)).tap { _1.set_form_data(code:) })

  def self.revoke(number) = call(Net::HTTP::Delete.new(path_of(number)))

  def self.path_of(number) = "/compartments/#{number}/code"

  def self.call(request)
    Net::HTTP.start(URL.host, URL.port, open_timeout: 2, read_timeout: 2) { _1.request(request).value }
  rescue Net::OpenTimeout, Net::ReadTimeout
    raise TimedOut, "the locker controller did not answer #{request.method} #{request.path}"
  end
  private_class_method :path_of, :call
end

# The system the tests hold to shelf.qnt, and a driver that stops each
# reservation between its read and its write with QuintDriver::Hold.
class Shelf
  attr_accessor :stock, :reserved

  def initialize
    @stock = 3
    @reserved = 0
  end

  # Reads the stock, then writes it back one lower, with no lock between.
  def reserve
    left = stock
    self.stock = left - 1
    self.reserved += 1
  end
end

class ShelfDriver
  SPEC = File.expand_path("shelf.qnt", __dir__)

  def step(action, picks)
    case action
    when "init"
      @hold = QuintDriver::Hold.new
      @shelf = Shelf.new
      hold = @hold
      # The pause point: right after the reservation reads the stock.
      @shelf.define_singleton_method(:stock) { super().tap { hold.pause(_1) } }
      @loaded = {}
    when "load" then @loaded[picks["r"]] = @hold.start(picks["r"]) { @shelf.reserve }
    when "save" then @hold.finish(picks["r"]).then { @loaded.delete(picks["r"]) }
    end
  end

  def state = { "stock" => @shelf.stock, "reserved" => @shelf.reserved, "loaded" => @loaded }
end

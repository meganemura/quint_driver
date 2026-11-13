module QuintDriver
  # Stops a call part way and lets it go on in a later step, so a spec can
  # split one request into the step that loads and the step that saves, and
  # put another request between them. The code under test calls #pause at
  # the point to stop, usually through a stub the driver installs; outside a
  # held call #pause does nothing, so the same stub is harmless elsewhere.
  #
  # A held call runs in a Fiber on the same thread, so it shares the
  # thread's database connection: a test that rolls back rolls the held call
  # back too, and no second connection is needed. On one connection the
  # transactions of two held calls nest, so pause where the call holds no
  # open transaction, such as after its read and before the transaction
  # that writes. Two calls held inside their transactions and finished in
  # the order they started leave ActiveRecord rolling back a transaction
  # SQLite no longer has.
  class Hold
    def initialize
      @held = {}
      @ours = Set.new
    end

    # Runs the block until it calls #pause, and returns the value given to
    # #pause. When the block ends without a pause, nothing is held and the
    # block's value is returned. An error the block raises comes out here.
    def start(name, &block)
      raise ArgumentError, "quint: #{name.inspect} is already held; finish it first" if held?(name)

      fiber = Fiber.new { [ :done, block.call ] }
      @ours << fiber
      @held[name] = fiber
      run(name, fiber)
    end

    # Lets the call held as +name+ run to its end, through any later pause,
    # and returns the block's value. An error the call raises comes out here.
    def finish(name)
      fiber = @held[name] or raise ArgumentError, "quint: nothing is held as #{name.inspect}; held: #{held.inspect}"
      value = run(name, fiber) while held?(name)
      value
    end

    def held?(name) = @held.key?(name)

    # The names of the calls that are stopped now, in the order they started.
    def held = @held.keys

    # Called by the code under test where a held call stops. +value+ is what
    # #start returns, such as the row the call loaded.
    def pause(value = nil)
      Fiber.yield([ :paused, value ]) if @ours.include?(Fiber.current)
      nil
    end

    private
      def run(name, fiber)
        kind, value = fiber.resume
        forget(name, fiber) if kind == :done
        value
      rescue Exception
        forget(name, fiber)
        raise
      end

      def forget(name, fiber)
        @held.delete(name)
        @ours.delete(fiber)
      end
  end
end

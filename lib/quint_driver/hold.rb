# rbs_inline: enabled

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
  #
  # The block runs as a Fiber, so it ends with `next`, not `return` or
  # `break`, and it does not call Fiber.yield itself. A pause from a Fiber
  # inside the held call, such as one Enumerator#next runs, cannot stop the
  # call, so it raises instead of letting the call run through unheld.
  #
  # +N+ is the type of the names a Hold keys its calls by. What a call
  # returns, or gives #pause, is the system's own value, so it stays untyped.
  #
  # @rbs generic N < Object
  class Hold
    # @rbs @held: Hash[N, Fiber]
    # @rbs @ours: Set[Fiber]
    # @rbs @running: N?

    # @rbs return: void
    def initialize
      @held = {}
      @ours = Set.new
      @running = nil
    end

    # Runs the block until it calls #pause, and returns the value given to
    # #pause. When the block ends without a pause, nothing is held and the
    # block's value is returned. An error the block raises comes out here.
    # A name is any value a Hash can key.
    #
    # @rbs name: N
    # @rbs &block: () -> untyped
    # @rbs return: untyped
    def start(name, &block)
      raise ArgumentError, "quint: #{name.inspect} is already held; finish it first" if held?(name)

      fiber = Fiber.new { [ :done, block.call ] }
      @ours << fiber
      @held[name] = fiber
      run(name, fiber)
    end

    # Lets the call held as +name+ run to its end, through any later pause,
    # and returns the block's value. An error the call raises comes out here.
    #
    # @rbs name: N
    # @rbs return: untyped
    def finish(name)
      fiber = @held[name] or raise ArgumentError, "quint: nothing is held as #{name.inspect}; held: #{held.inspect}"
      value = run(name, fiber) while held?(name)
      value
    end

    # @rbs name: N
    # @rbs return: bool
    def held?(name) = @held.key?(name)

    # The names of the calls that are stopped now, in the order they started.
    #
    # @rbs return: Array[N]
    def held = @held.keys

    # Called by the code under test where a held call stops. +value+ is what
    # #start returns, such as the row the call loaded.
    #
    # @rbs value: untyped
    # @rbs return: nil
    def pause(value = nil)
      if @ours.include?(Fiber.current)
        Fiber.yield([ :paused, value ])
      elsif @running
        raise ArgumentError, "quint: #{@running.inspect} paused in a Fiber of its own, such as one Enumerator#next runs; " \
                             "pause where the held call runs, outside that Fiber"
      end
      nil
    end

    private
      # @rbs name: N
      # @rbs fiber: Fiber
      # @rbs return: untyped
      def run(name, fiber)
        outer, @running = @running, name
        answer = fiber.resume
        kind, value = answer
        unless %i[paused done].include?(kind) && answer.is_a?(Array)
          raise ArgumentError, "quint: #{name.inspect} called Fiber.yield itself; a held call stops only at pause"
        end

        forget(name, fiber) if kind == :done
        value
      rescue Exception
        forget(name, fiber)
        raise
      ensure
        @running = outer
      end

      # @rbs name: N
      # @rbs fiber: Fiber
      # @rbs return: void
      def forget(name, fiber)
        @held.delete(name)
        @ours.delete(fiber)
      end
  end
end

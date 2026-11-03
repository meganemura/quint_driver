# The system the tests hold to loans.qnt, and a driver that runs the spec's
# actions on it. BrokenLoans forgets the one-book limit.
class Loans
  class Refused < StandardError
    attr_reader :reason

    def initialize(reason)
      @reason = reason
      super(reason.to_s)
    end
  end

  def initialize = @holders = {}

  def borrow(member, book)
    raise Refused.new(:on_loan) if @holders.key?(book)
    raise Refused.new(:limit_reached) if limited? && @holders.value?(member)

    @holders[book] = member
  end

  def give_back(book)
    @holders.delete(book) || raise(Refused.new(:not_on_loan))
  end

  def holder(book) = @holders[book]

  private
    def limited? = true
end

class BrokenLoans < Loans
  private
    def limited? = false
end

class LoansDriver
  SPEC = File.expand_path("loans.qnt", __dir__)
  BOOKS = %w[b1 b2 b3].freeze

  def self.spec = @spec ||= QuintDriver::Spec.new(SPEC, main: "loans")

  def initialize(system = Loans)
    @system = system
  end

  def step(action, picks)
    @outcome = "Done"
    case action.delete_suffix("_refused")
    when "init" then @loans = @system.new
    when "borrow" then @loans.borrow(picks.fetch("m"), picks.fetch("b"))
    when "give_back" then @loans.give_back(picks.fetch("b"))
    else raise ArgumentError, "no command for the action #{action}"
    end
  rescue Loans::Refused => refusal
    @outcome = [ "Refused", refusal.reason.to_s ]
  end

  def state
    { "holder" => BOOKS.to_h { [ _1, @loans.holder(_1) || "" ] }, "outcome" => @outcome }
  end
end

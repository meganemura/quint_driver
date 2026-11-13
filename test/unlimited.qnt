// Lending as BrokenLoans in examples/loans does it: a member can borrow a
// second book. The spec models the code as written, so LoansDriver over
// BrokenLoans agrees with it at every step, and its expectations say what
// should hold. The tests use it to see an expectation break where the
// system agrees with the spec, and Loans, which keeps the limit, to see a
// disagreement stay one.
module unlimited {
  type Outcome = Done | Refused(str)

  pure val BOOKS = Set("b1", "b2", "b3")
  pure val MEMBERS = Set("m1", "m2")

  var holder: str -> str
  var outcome: Outcome

  action init = all {
    holder' = BOOKS.mapBy(_ => ""),
    outcome' = Done,
  }

  action borrow(m: str, b: str): bool = all {
    holder.get(b) == "",
    holder' = holder.set(b, m),
    outcome' = Done,
  }
  action borrow_refused(m: str, b: str): bool = all {
    holder.get(b) != "",
    holder' = holder,
    outcome' = Refused("on_loan"),
  }
  action give_back(b: str): bool = all {
    holder.get(b) != "",
    holder' = holder.set(b, ""),
    outcome' = Done,
  }
  action give_back_refused(b: str): bool = all {
    holder.get(b) == "",
    holder' = holder,
    outcome' = Refused("not_on_loan"),
  }

  action step = any {
    nondet m = MEMBERS.oneOf()
    nondet b = BOOKS.oneOf()
    any { borrow(m, b), borrow_refused(m, b) },
    nondet b = BOOKS.oneOf()
    any { give_back(b), give_back_refused(b) },
  }

  // Breaks once a member borrows a second book.
  val one_book_each = MEMBERS.forall(m => BOOKS.filter(b => holder.get(b) == m).size() <= 1)
  // Breaks once every book is on loan.
  val one_on_the_shelf = BOOKS.exists(b => holder.get(b) == "")
  // Holds: only a member borrows.
  val lent_to_members = BOOKS.forall(b => holder.get(b) == "" or MEMBERS.contains(holder.get(b)))
}

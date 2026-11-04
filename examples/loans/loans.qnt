// A lending shelf: a member borrows one book at a time, and gives it back.
// Each command has a refused twin, so a trace checks the refusals too.
module loans {
  type Outcome = Done | Refused(str)

  pure val BOOKS = Set("b1", "b2", "b3")
  pure val MEMBERS = Set("m1", "m2")
  pure val NOBODY = ""

  var holder: str -> str
  var outcome: Outcome

  pure def onLoan(h: str -> str, b: str): bool = h.get(b) != NOBODY
  pure def holds(h: str -> str, m: str): bool = BOOKS.exists(b => h.get(b) == m)
  pure def borrowRefusal(h: str -> str, m: str, b: str): str =
    if (onLoan(h, b)) "on_loan" else if (holds(h, m)) "limit_reached" else ""

  action init = all {
    holder' = Map("b1" -> NOBODY, "b2" -> NOBODY, "b3" -> NOBODY),
    outcome' = Done,
  }

  action borrow(m: str, b: str): bool = all {
    borrowRefusal(holder, m, b) == "",
    holder' = holder.put(b, m),
    outcome' = Done,
  }
  action borrow_refused(m: str, b: str): bool = all {
    borrowRefusal(holder, m, b) != "",
    holder' = holder,
    outcome' = Refused(borrowRefusal(holder, m, b)),
  }
  action give_back(b: str): bool = all {
    onLoan(holder, b),
    holder' = holder.put(b, NOBODY),
    outcome' = Done,
  }
  action give_back_refused(b: str): bool = all {
    not(onLoan(holder, b)),
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

  val one_book_each = MEMBERS.forall(m => BOOKS.filter(b => holder.get(b) == m).size() <= 1)
  // False once a book is lent: the tests use it to see a broken invariant reported.
  val nothing_on_loan = BOOKS.forall(b => not(onLoan(holder, b)))
  // True once two books are lent: the tests ask quint for traces that reach it.
  val two_on_loan = BOOKS.filter(b => onLoan(holder, b)).size() == 2
}

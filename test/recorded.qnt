// One variable holds the whole state, as a Choreo spec keeps it, and records
// the action each step took with its picks: quint test writes no
// mbt::actionTaken, so a named run says what it ran this way.
module recorded {
  type Taken = Init | Borrow({ m: str, b: str }) | GiveBack({ b: str })

  var s: { books: str -> str, taken: Taken }

  pure val BOOKS = Set("b1", "b2")

  action init = s' = { books: BOOKS.mapBy(_ => ""), taken: Init }

  action borrow(m: str, b: str): bool = all {
    s.books.get(b) == "",
    not(s.books.keys().exists(k => s.books.get(k) == m)),
    s' = { books: s.books.set(b, m), taken: Borrow({ m: m, b: b }) },
  }

  action give_back(b: str): bool = all {
    s.books.get(b) != "",
    s' = { books: s.books.set(b, ""), taken: GiveBack({ b: b }) },
  }

  action step = any {
    nondet m = Set("m1", "m2").oneOf()
    nondet b = BOOKS.oneOf()
    borrow(m, b),
    nondet b = BOOKS.oneOf()
    give_back(b),
  }

  run lendTest = init.then(borrow("m1", "b1")).then(borrow("m2", "b2")).then(give_back("b1"))
  // Fails in quint: the tests use it to see a failed run reported.
  run unlentTest = init.then(borrow("m1", "b1")).expect(s.books.get("b1") == "")
}

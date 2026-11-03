// Uses each operator the Ruby model evaluates that loans.qnt does not, so
// replaying Quint's traces through the model checks those operators too.
module operators {
  type Shape = Circle(int) | Square(int) | Dot

  pure val NUMS = Set(0, 1, 2, 3)

  var total: int
  var picked: Set[int]
  var last: int -> int
  var count: { n: int, full: bool }
  var pair: (int, str)
  var shape: Shape
  var facts: {
    lt: bool, lte: bool, gt: bool, gte: bool, both: bool, either: bool, implied: bool, same: bool,
    within: bool, doubled: Set[int], shared: Set[int], seen: Set[int], after: int, grown: int,
  }

  pure def twice(v: int): int = v + v
  // An operator defined as another operator's name.
  pure def doubleOf = twice

  pure def factsOf(a: int, total: int, picked: Set[int], last: int -> int): {
    lt: bool, lte: bool, gt: bool, gte: bool, both: bool, either: bool, implied: bool, same: bool,
    within: bool, doubled: Set[int], shared: Set[int], seen: Set[int], after: int, grown: int,
  } = {
    val after = a + 1
    {
      lt: a < total, lte: a <= total, gt: a > total, gte: a >= total,
      both: a > 0 and a < 3,
      either: a == 0 or a == 3,
      implied: (a < total) implies (a == 0),
      same: (a > total) iff (a >= 2),
      within: Set(a).subseteq(picked),
      doubled: picked.map(v => v + v),
      shared: picked.intersect(Set(a, after)),
      seen: last.keys(),
      after: after,
      grown: doubleOf(a),
    }
  }

  action init = all {
    total' = 0,
    picked' = Set(),
    last' = Map(),
    count' = { n: 0, full: false },
    pair' = (0, ""),
    shape' = Dot,
    facts' = factsOf(0, 0, Set(), Map()),
  }

  action add(a: int): bool = all {
    not(a.in(picked)),
    total' = total + a,
    picked' = picked.union(Set(a)),
    last' = last.put(a, total),
    count' = count.with("n", count.n + 1),
    pair' = (a, pair._2),
    shape' = if (a > total) Circle(a) else Square(a),
    facts' = factsOf(a, total, picked, last),
  }

  action drop(a: int): bool = all {
    picked.contains(a),
    total' = total - a,
    picked' = picked.exclude(Set(a)),
    last' = last,
    count' = { n: count.n, full: picked.size() >= 3 },
    pair' = (pair._1, "dropped"),
    shape' = match shape {
      | Circle(n) => Square(n + 1)
      | _ => Dot
    },
    facts' = factsOf(a, total, picked, last),
  }

  action step = {
    nondet a = NUMS.oneOf()
    any { add(a), drop(a) }
  }
}

// What the Ruby model refuses to evaluate, rather than guess at.
module unsupported {
  var n: int
  var m: int

  action init = all { n' = 1, m' = 1 }
  action double = all { n' = n * 2, m' = m }
  // Quint drops a variable an action leaves unassigned from the next state.
  action bump = n' = n + 1
  action step = double
}

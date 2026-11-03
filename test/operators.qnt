// Uses each operator the Ruby model evaluates that loans.qnt does not, so
// replaying Quint's traces through the model checks those operators too.
// Its step names actions without arguments, nests an `any`, and draws from
// sets that can be empty. `count` has a field named `value`, a key ITF also
// gives a variant.
module operators {
  type Shape = Circle(int) | Square(int) | Dot

  pure val NUMS = Set(0, 1, 2, 3)

  var total: int
  var picked: Set[int]
  var last: int -> int
  var count: { value: int, full: bool }
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
    count' = { value: 0, full: false },
    pair' = (0, ""),
    shape' = Dot,
    facts' = factsOf(0, 0, Set(), Map()),
  }

  action add(a: int): bool = all {
    not(a.in(picked)),
    total' = total + a,
    picked' = picked.union(Set(a)),
    last' = last.put(a, total),
    count' = count.with("value", count.value + 1),
    pair' = (a, pair._2),
    shape' = if (a > total) Circle(a) else Square(a),
    facts' = factsOf(a, total, picked, last),
  }

  action drop(a: int): bool = all {
    picked.contains(a),
    total' = total - a,
    picked' = picked.exclude(Set(a)),
    last' = last,
    count' = { value: count.value, full: picked.size() >= 3 },
    pair' = (pair._1, "dropped"),
    shape' = match shape {
      | Circle(n) => Square(n + 1)
      | _ => Dot
    },
    facts' = factsOf(a, total, picked, last),
  }

  action reset = all {
    total' = 0,
    picked' = Set(),
    last' = last,
    count' = count,
    pair' = pair,
    shape' = Dot,
    facts' = facts,
  }

  action moves = any {
    nondet a = NUMS.exclude(picked).oneOf()
    add(a),
    nondet b = picked.oneOf()
    drop(b),
  }

  action step = any { moves, reset }
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

// After two ticks no move is enabled, so a sequence has to stop there.
module countdown {
  var n: int

  action init = n' = 2
  action tick = all { n > 0, n' = n - 1 }
  action step = tick
}

// Each move picks a value of a sum type, so a trace's pick has to become
// the model's own variant before the model can compare or match it.
module painting {
  type Color = Red | Blue | Mixed(int)

  var color: Color
  var mixed: int

  action init = all { color' = Red, mixed' = 0 }

  action paint(c: Color): bool = all {
    c != color,
    color' = c,
    mixed' = match c { Mixed(n) => mixed + n | _ => mixed },
  }

  action step = {
    nondet c = Set(Red, Blue, Mixed(1), Mixed(2)).oneOf()
    any { paint(c) }
  }
}

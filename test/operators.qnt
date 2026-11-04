// Uses each operator the Ruby model evaluates that loans.qnt does not, so
// replaying Quint's traces through the model checks those operators too.
// `queue` keeps the order of the picks, so the list operators see lists of
// every length up to the longest trace, the empty one included.
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
  var queue: List[int]
  var listed: ListFacts
  var facts: {
    lt: bool, lte: bool, gt: bool, gte: bool, both: bool, either: bool, implied: bool, same: bool,
    within: bool, doubled: Set[int], shared: Set[int], seen: Set[int], after: int, grown: int,
    keyed: int -> int, reset: int -> int, bumped: int -> int, paired: int -> int,
  }

type ListFacts = {
    first: int, rest: List[int], len: int, last: int, positions: Set[int], replaced: List[int],
    after: List[int], upTo: List[int], big: List[int], digits: int, joined: List[int], negated: int,
    product: int, half: int, left: int, span: Set[int], weighed: int, reversed: int,
  }
  
  // q.append(a) is never empty, so head, tail and nth are defined on it.
  // foldl builds digits and foldr reversed, which depend on the order they fold in.
  pure def listFactsOf(a: int, q: List[int]): ListFacts = {
    val l = q.append(a)
    {
      first: l.head(),
      rest: l.tail(),
      len: l.length(),
      last: l.nth(l.length() - 1),
      positions: l.indices(),
      replaced: l.replaceAt(0, a * 3),
      after: l.slice(1, l.length()),
      upTo: range(0, a),
      big: l.select(x => x > 1),
      digits: l.foldl(0, (acc, x) => acc * 10 + x),
      joined: q.concat([a, -a]),
      negated: -a,
      product: a * l.length(),
      half: (a + l.length()) / 2,
      left: (a + l.length()) % 3,
      span: (-a).to(a),
      weighed: l.indices().fold(0, (acc, i) => acc + i * l.nth(i)),
      reversed: l.foldr(0, (x, acc) => acc * 10 + x),
    }
  }

  pure def twice(v: int): int = v + v
  // An operator defined as another operator's name.
  pure def doubleOf = twice

  pure def factsOf(a: int, total: int, picked: Set[int], last: int -> int): {
    lt: bool, lte: bool, gt: bool, gte: bool, both: bool, either: bool, implied: bool, same: bool,
    within: bool, doubled: Set[int], shared: Set[int], seen: Set[int], after: int, grown: int,
    keyed: int -> int, reset: int -> int, bumped: int -> int, paired: int -> int,
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
      keyed: picked.mapBy(v => v * 2),
      reset: last.put(a, total).set(a, after),
      bumped: last.put(a, total).setBy(a, v => v + 1),
      paired: Set((a, total), (after, a)).setToMap(),
    }
  }

  action init = all {
    total' = 0,
    picked' = Set(),
    last' = Map(),
    count' = { value: 0, full: false },
    pair' = (0, ""),
    shape' = Dot,
    queue' = [],
    listed' = listFactsOf(0, []),
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
    queue' = queue.append(a),
    listed' = listFactsOf(a, queue),
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
    queue' = queue.select(x => x != a),
    listed' = listFactsOf(a, queue),
    facts' = factsOf(a, total, picked, last),
  }

  action reset = all {
    total' = 0,
    picked' = Set(),
    last' = last,
    count' = count,
    pair' = pair,
    shape' = Dot,
    queue' = List(),
    listed' = listed,
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
  // The model does not evaluate powerset.
  pure def subsets(s: Set[int]): Set[Set[int]] = s.powerset()
  action double = all { n' = subsets(Set(n)).size(), m' = m }
  // Quint documents no rounding for a negative operand of / or %.
  action halve = all { n' = (-n) / 2, m' = m }
  action parity = all { n' = (-n) % 2, m' = m }
  // Quint leaves the head of an empty list undefined.
  action first = all { n' = List().head(), m' = m }
  // Quint leaves set and setBy at a key the map does not have undefined.
  action overwrite = all { n' = Map(1 -> n).set(2, n).keys().size(), m' = m }
  action bumpMissing = all { n' = Map("a" -> n).setBy("b", v => v + 1).keys().size(), m' = m }
  // Which of two pairs with one key setToMap keeps depends on the set's order.
  action pairUp = all { n' = Set((1, n), (1, n + 1)).setToMap().keys().size(), m' = m }
  // Quint drops a variable an action leaves unassigned from the next state.
  action bump = n' = n + 1
  action resize(s: Set[int]): bool = all { n' = s.size(), m' = m }
  // A move's domain is written in the action that draws it, not in step.
  action picking = any {
    nondet s = Set(n).powerset().oneOf()
    resize(s),
  }
  // A domain written above a nested choice is written in step, not in the
  // action that holds the choice.
  action grow = all { n' = n + 1, m' = m }
  action growing = any { grow }
  action step = any {
    double,
    picking,
    nondet t = Set(m).powerset().oneOf()
    growing,
  }
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

  // Derived from a variant, so an observed value has to read the trace's
  // variant as the model's own.
  val shade = match color { Mixed(n) => n | _ => 0 }
  val red = color == Red
  def tint = shade + 1
  pure def white = 0

  action step = {
    nondet c = Set(Red, Blue, Mixed(1), Mixed(2)).oneOf()
    any { paint(c) }
  }
}

// A step whose one move leaves m unassigned, which Quint allows and the
// model refuses rather than guess at m's next value.
module unassigned {
  var n: int
  var m: int

  action init = all { n' = 0, m' = 0 }
  action bump = n' = n + 1
  action step = any { bump }
}

// One domain is the same in every state, one reads an earlier pick, and one
// reads a variable, so only the first can be evaluated once.
module pairing {
  pure val NUMS = Set(1, 2, 3)

  var pairs: Set[(int, int)]

  action init = pairs' = Set()
  action pair(a: int, b: int): bool = pairs' = pairs.union(Set((a, b)))
  action unpair(p: (int, int)): bool = pairs' = pairs.exclude(Set(p))

  action step = any {
    nondet a = NUMS.oneOf()
    nondet b = NUMS.exclude(Set(a)).oneOf()
    pair(a, b),
    nondet p = pairs.oneOf()
    unpair(p),
  }
}

// An Option variable, and a pick whose domain holds None, so a replay and
// the machine have to hand a driver the same Ruby value for each.
module approval {
  type Approver = None | Some(str)

  var last: Approver
  var approvals: int

  action init = all { last' = None, approvals' = 0 }
  action approve(by: Approver): bool = all { last' = by, approvals' = approvals + 1 }

  val approved = last != None

  action step = any {
    nondet by = Set(None, Some("grace"), Some("ada")).oneOf()
    approve(by),
  }
}

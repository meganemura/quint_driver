// A step whose arms name no action, so no command answers them.
module anonymous {
  var n: int

  action init = n' = 0
  action step = any { n' = n + 1, n' = n + 2 }
}

// The arm that names no action sits in an action step opens in place.
module nested {
  var n: int

  action init = n' = 0
  action counting = any { n' = n + 1 }
  action step = any { counting }
}

// An arm that is a conjunction of assignments, not a call of an action.
module conjunction {
  var n: int
  var m: int

  action init = all { n' = 0, m' = 0 }
  action step = any { all { n' = n + 1, m' = m } }
}

// A step that is one `all` around its picks and the `any` of its actions.
module wrapped {
  var n: int

  action init = n' = 0
  action add(x: int): bool = n' = n + x
  action sub(x: int): bool = n' = n - x
  action step = all {
    nondet x = Set(1, 2).oneOf()
    any { add(x), sub(x) }
  }
}

// An action whose val reads a map before the guard that makes its key one,
// and a def with a parameter inside the action.
module nested {
  pure val KEYS = Set(1, 2)
  var owner: int -> str
  var n: int
  action init = all { owner' = Map(1 -> "a"), n' = 0 }
  action take(k: int): bool = {
    val o = owner.get(k)
    def bump(x) = x + 1
    all { owner.keys().contains(k), o == "a", n' = bump(n), owner' = owner }
  }
  action step = any { nondet k = KEYS.oneOf() take(k) }
}

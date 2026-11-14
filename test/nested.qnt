// An action whose val reads a map before the guard that makes its key one,
// a def with a parameter inside the action that shadows a top-level def of
// the same name, and an operator passed as a parameter.
module nested {
  pure val KEYS = Set(1, 2)
  pure def bump(x: int): int = x + 10
  pure def twice(f: int => int, x: int): int = f(f(x))
  var owner: int -> str
  var n: int
  action init = all { owner' = Map(1 -> "a"), n' = 0 }
  action take(k: int): bool = {
    val o = owner.get(k)
    def bump(x) = x + 1
    all { owner.keys().contains(k), o == "a", n' = twice(bump, n), owner' = owner }
  }
  action step = any { nondet k = KEYS.oneOf() take(k) }
}

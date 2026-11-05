module base {
  var shared: int
  action init = shared' = 0
  action base_step = shared' = shared + 1
}

module uses_base {
  import base.*
}

// One declaration of each kind a step or a reach can name by mistake.
module kinds {
  import base.*
  type Status = Idle | Lent(str)
  const LIMIT: int
  var n: int
  pure val MAX = 3
  val BOOKS = Set("a")
  pure def double(x: int): int = x * 2
  val done = n == 0
  def at_limit = n == LIMIT
  action step = all { n' = n + 1, shared' = shared }
  action add(k: int): bool = all { n' = n + k, shared' = shared }
  run walk = init.then(base_step)
  temporal always_small = always(n < 10)
}

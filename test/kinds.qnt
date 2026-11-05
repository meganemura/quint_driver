module base {
  var shared: int
  action init = shared' = 0
  action base_step = shared' = shared + 1
  action moves = any { base_step }
  val started = shared > 0
  val doubled = shared * 2
  pure def twice(x: int): int = x * 2
  run twice_then = init.then(base_step)
  temporal stays_small = always(shared < 10)
}

module uses_base {
  import base.*
}

module reexports {
  import base.*
  export base.*
}

module via_export {
  import reexports.*
}

module one_name {
  import base.shared
  import base.init
  import base.base_step
}

module names_base {
  import base as B
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

module helpers {
  pure def double(x: int): int = x * 2
}

// Starts with an action that is not named init, and imports only a pure def.
module begins {
  import helpers.*
  var m: int
  action begin = m' = 0
  action tick = m' = double(m) + 1
  action step = any { tick }
}

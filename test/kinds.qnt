module base {
  var shared: int
  action init = shared' = 0
  action base_step = shared' = shared + 1
}

module uses_base {
  import base.*
}

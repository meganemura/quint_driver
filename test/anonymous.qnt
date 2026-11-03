// A step whose arms name no action, so no command answers them.
module anonymous {
  var n: int

  action init = n' = 0
  action step = any { n' = n + 1, n' = n + 2 }
}

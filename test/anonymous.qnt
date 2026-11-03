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

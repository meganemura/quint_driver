// A shelf of three items, and reservations that each read the stock, then
// write it back one lower. The spec splits a reservation into the step that
// reads and the step that writes, so another reservation can come between.
module shelf {
  pure val REQUESTS = Set("r1", "r2")

  var stock: int
  var reserved: int
  var loaded: str -> int  // the stock each reservation read and has not written yet

  // What the owner expects: every reservation takes one item off the shelf.
  val every_reservation_takes_one = stock + reserved == 3

  action init = all {
    stock' = 3,
    reserved' = 0,
    loaded' = Map(),
  }

  action load(r: str): bool = all {
    not(loaded.keys().contains(r)),
    loaded' = loaded.put(r, stock),
    stock' = stock, reserved' = reserved,
  }

  action save(r: str): bool = all {
    loaded.keys().contains(r),
    stock' = loaded.get(r) - 1,
    reserved' = reserved + 1,
    loaded' = loaded.keys().exclude(Set(r)).mapBy(k => loaded.get(k)),
  }

  action step = any {
    nondet r = REQUESTS.oneOf()
    any { load(r), save(r) },
  }
}

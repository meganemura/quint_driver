// The depot as its code is written: three parcels it expects, two compartments,
// the locker controller outside, and one delivery's intake.
module depot {
  pure val PARCELS = Set("p1", "p2", "p3")
  // The rows of the intake, in the order of its manifest.
  pure val MANIFEST = ["p1", "p2", "p3"]
  pure val COMPARTMENTS = Set(1, 2)
  // The compartment the locker controller times out for during a step, 0 for none.
  pure val OFFLINE = COMPARTMENTS.union(Set(0))

  type Place = Waiting | In(int) | Collected | Withdrawn
  // What a run of the intake job has done so far.
  type Job = { place: str -> Place, live: Set[int], row: str -> str, raised: bool }

  var place: str -> Place  // where each parcel is
  var live: Set[int]       // the compartments whose pickup code the locker controller holds
  var row: str -> str      // each parcel's row of the intake: "" for none, "pending", "done" or "failed"
  var intake: str          // "none", "open" from the manifest until the job reaches its end, then "finished"
  var everDone: Set[str]   // the parcels whose row was done at some time

  def taken(places, c) = PARCELS.exists(p => places.get(p) == In(c))
  // The free compartment with the lowest number, 0 when none is free.
  def firstFree(places) =
    COMPARTMENTS.filter(c => not(taken(places, c))).fold(0, (low, c) => if (low == 0 or c < low) c else low)

  // What the operator expects.
  val taken_compartment_has_live_code = COMPARTMENTS.forall(c => taken(place, c) implies live.contains(c))
  val free_compartment_has_no_code = COMPARTMENTS.forall(c => live.contains(c) implies taken(place, c))
  val done_row_stays_done = everDone.forall(p => row.get(p) == "done")
  val finished_job_leaves_no_row_pending = intake == "finished" implies PARCELS.forall(p => row.get(p) != "pending")

  action init = all {
    place' = PARCELS.mapBy(_ => Waiting),
    live' = Set(),
    row' = PARCELS.mapBy(_ => ""),
    intake' = "none",
    everDone' = Set(),
  }

  // The assignment page puts a waiting parcel in the first free compartment.
  action assignParcel(p: str, offline: int): bool = {
    val c = firstFree(place)
    all {
      place.get(p) == Waiting,
      c != 0,
      place' = place.set(p, In(c)),
      live' = if (c == offline) live else live.union(Set(c)),
      row' = row, intake' = intake, everDone' = everDone,
    }
  }

  // The release page, when the receiver has picked the parcel up.
  action release(p: str, offline: int): bool = {
    val c = match place.get(p) { | In(n) => n | _ => 0 }
    all {
      c != 0,
      place' = place.set(p, Collected),
      live' = if (c == offline) live else live.exclude(Set(c)),
      row' = row, intake' = intake, everDone' = everDone,
    }
  }

  // The withdrawal page, when the sender took a waiting parcel back.
  action withdraw(p: str): bool = all {
    place.get(p) == Waiting,
    place' = place.set(p, Withdrawn),
    live' = live, row' = row, intake' = intake, everDone' = everDone,
  }

  // The intake page, with a manifest of every parcel that was not withdrawn.
  action takeIn = all {
    intake == "none",
    row' = PARCELS.mapBy(p => if (place.get(p) == Withdrawn) "" else "pending"),
    intake' = "open",
    place' = place, live' = live, everDone' = everDone,
  }

  // One row's turn in a run of the job. A time-out raises, which ends the run.
  def turn(job: Job, p: str, offline: int): Job = {
    val c = firstFree(job.place)
    if (job.raised or job.row.get(p) == "") job
    else if (job.place.get(p) == Withdrawn) job
    else if (job.place.get(p) != Waiting or c == 0) { ...job, row: job.row.set(p, "failed") }
    else if (c == offline) { ...job, raised: true }
    else { ...job, place: job.place.set(p, In(c)), live: job.live.union(Set(c)), row: job.row.set(p, "done") }
  }

  // One run of the intake job: its first, or the retry after a run that raised.
  action runJob(offline: int): bool = {
    val ran = MANIFEST.foldl({ place: place, live: live, row: row, raised: false }, (job, p) => turn(job, p, offline))
    all {
      intake == "open",
      place' = ran.place,
      live' = ran.live,
      row' = ran.row,
      intake' = if (ran.raised) "open" else "finished",
      everDone' = everDone.union(PARCELS.filter(p => ran.row.get(p) == "done")),
    }
  }

  action step = any {
    nondet p = PARCELS.oneOf()
    nondet offline = OFFLINE.oneOf()
    any { assignParcel(p, offline), release(p, offline) },
    nondet p = PARCELS.oneOf()
    withdraw(p),
    takeIn,
    nondet offline = OFFLINE.oneOf()
    runJob(offline),
  }
}

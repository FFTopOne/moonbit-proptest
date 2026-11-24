///|
/// Edge cases of the random source.

///|
test "next_int covers both signs" {
  // `next_int` exists so callers can draw a full 32-bit value without going
  // through a bounded range. A sampler that shifted instead of truncating would
  // quietly lose the sign bit and only ever produce non-negative values.
  let rng = Rng::new(5UL)
  let mut negatives = 0
  let mut positives = 0
  let mut index = 0
  while index < 200 {
    let value = rng.next_int()
    if value < 0 {
      negatives = negatives + 1
    } else if value > 0 {
      positives = positives + 1
    }
    index = index + 1
  }
  assert_true(negatives > 0)
  assert_true(positives > 0)
}

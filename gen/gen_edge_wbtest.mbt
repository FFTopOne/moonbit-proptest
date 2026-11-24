///|
/// Edge cases of the generator API.
///
/// Kept apart from the behavioural tests in `gen.mbt` because these are about
/// degenerate inputs rather than shrink quality: refusals, empty choices, and
/// size plumbing. Every path here was reachable from the public API and had no
/// coverage at all, which is what a coverage pass is for.

///|
test "reject refuses to produce anything" {
  let rejected : Gen[Int32] = Gen::reject()
  assert_true(rejected.sample(seed=1UL) is None)
  assert_eq(rejected.samples(count=5, seed=1UL).length(), 0)
}

///|
test "flat_map propagates a refused outer draw" {
  let outer : Gen[Int32] = Gen::reject()
  let chained = outer.flat_map(n => Gen::pure(n + 1))
  assert_true(chained.sample() is None)
}

///|
test "flat_map propagates a refused inner draw" {
  let chained = Gen::pure(1).flat_map(fn(_n) { (Gen::reject() : Gen[Int32]) })
  assert_true(chained.sample() is None)
}

///|
test "zip pairs two independent draws" {
  let paired = Gen::pure(1).zip(Gen::pure(2))
  assert_eq(paired.sample().unwrap(), (1, 2))
}

///|
test "zip_with shrinks the left operand first, holding the right fixed" {
  let paired = int_range(0, 10).zip_with(int_range(0, 10), (a, b) => (a, b))
  let tree = paired.run(10, @rng.Rng::new(2UL)).unwrap()
  let (left, right) = tree.value
  let (first_left, first_right) = tree.follow([0]).unwrap().value
  assert_eq(first_left, 0)
  assert_eq(first_right, right)
  assert_true(left >= 0)
}

///|
test "resize pins the size a generator sees" {
  let observed = [0]
  let gen = Gen::sized(fn(size) {
    observed[0] = size
    Gen::pure(size)
  }).resize(7)
  assert_eq(gen.sample(size=100).unwrap(), 7)
  assert_eq(observed[0], 7)
}

///|
test "scale rewrites the size before the generator sees it" {
  let gen = Gen::sized(fn(size) { Gen::pure(size) }).scale(size => size * 2)
  assert_eq(gen.sample(size=5).unwrap(), 10)
}

///|
test "filter on a generator that never yields discards" {
  let empty : Gen[Int32] = Gen::reject()
  assert_true(empty.filter(x => x > 0).sample() is None)
}

///|
test "one_of of nothing discards instead of panicking" {
  let gen : Gen[Int32] = Gen::one_of([])
  assert_true(gen.sample() is None)
}

///|
test "frequency without a positive weight discards" {
  let gen : Gen[Int32] = frequency([(0, Gen::pure(1))])
  assert_true(gen.sample() is None)
}

///|
test "bool eventually draws both values" {
  let values = bool().samples(count=40, seed=3UL)
  assert_true(values.contains(true))
  assert_true(values.contains(false))
}

///|
test "int_range with an empty range yields its bound" {
  assert_eq(int_range(5, 5).sample().unwrap(), 5)
  assert_eq(int_range(9, 4).sample().unwrap(), 9)
}

///|
test "int stays inside the run size" {
  for value in int().samples(count=60, size=20, seed=4UL) {
    assert_true(value >= -20 && value <= 20)
  }
}

///|
test "array_with_size discards when one element is refused" {
  let gen : Gen[Array[Int32]] = Gen::reject().array_with_size(3)
  assert_true(gen.sample() is None)
}

///|
test "option_of discards when the coin says some but the inner refuses" {
  // Roughly half the draws never touch the inner generator, so this only
  // covers the refusal path when a few seeds are tried.
  let gen : Gen[Int32?] = Gen::reject().option_of()
  let mut refusals = 0
  for index in 0..<40 {
    let seed = @rng.derive_seed(21UL, index)
    if gen.run(10, @rng.Rng::new(seed)) is None {
      refusals = refusals + 1
    }
  }
  assert_true(refusals > 0)
}

///|
test "result_of produces both sides" {
  let gen = Gen::result_of(Gen::pure(1), Gen::pure("boom"))
  let values = gen.samples(count=90, seed=8UL)
  let mut oks = 0
  for value in values {
    match value {
      Ok(_) => oks = oks + 1
      Err(_) => ()
    }
  }
  assert_true(oks > 0)
  assert_true(oks < values.length())
}

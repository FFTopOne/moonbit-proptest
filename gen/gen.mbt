///|
/// A size-aware generator of shrink trees.
///
/// The crucial difference from a value-only generator is the return type of
/// `run`: it yields the generated value *together with the tree of every way
/// that value could have been simpler*. Shrinking therefore never has to guess
/// from the value alone — it walks a structure that the generator already knew
/// about while producing it. In particular `flat_map` can shrink the value
/// that chose the shape of the result, which a separate per-type shrinker
/// cannot express.
///
/// `run` returns `None` when the generator declines to produce a value, for
/// instance because a `filter` predicate could not be satisfied. The runner
/// counts those as discards instead of treating them as failures, so a
/// constrained generator degrades into a lower effective sample count rather
/// than into a false counterexample.
pub struct Gen[T] {
  run : (Int32, @rng.Rng) -> @tree.Tree[T]?
}

///|
/// Builds a generator from a size-and-randomness function.
pub fn[T] Gen::new(run : (Int32, @rng.Rng) -> @tree.Tree[T]?) -> Gen[T] {
  { run, }
}

///|
/// Draws one shrink tree, or `None` when the generator declined.
pub fn[T] Gen::run(
  self : Gen[T],
  size : Int32,
  rng : @rng.Rng,
) -> @tree.Tree[T]? {
  (self.run)(size, rng)
}

///|
/// A generator that always yields `value` and has nothing to shrink to.
pub fn[T] Gen::pure(value : T) -> Gen[T] {
  Gen::new(fn(_, _) { Some(@tree.Tree::singleton(value)) })
}

///|
/// A generator that never yields. Composing it into a pipeline makes the
/// whole pipeline discard, which is how `flat_map` propagates a failed draw.
pub fn[T] Gen::reject() -> Gen[T] {
  Gen::new(fn(_, _) { None })
}

///|
/// Transforms every value in the tree, keeping its shrink structure.
pub fn[T, U] Gen::map(self : Gen[T], f : (T) -> U) -> Gen[U] {
  Gen::new(fn(size, rng) { self.run(size, rng).map(t => t.map(f)) })
}

///|
/// Sequences a generator with a generator-producing function.
///
/// The result's shrink tree interleaves two kinds of simplification: shrinking
/// the outer value (and re-deriving the inner generator from the simpler outer
/// value), then shrinking the inner value. The first kind is what makes
/// dependent generators shrink sensibly — a property over "an array whose
/// length was itself generated" can shrink the length, not just the contents.
pub fn[T, U] Gen::flat_map(self : Gen[T], f : (T) -> Gen[U]) -> Gen[U] {
  Gen::new(fn(size, rng) {
    match self.run(size, rng) {
      None => None
      Some(outer) => {
        // Freeze the inner stream so that re-deriving the inner generator
        // during shrinking replays the same random choices.
        let inner_seed = rng.next_uint64()
        flat_map_tree(outer, f, size, inner_seed)
      }
    }
  })
}

///|
fn[T, U] flat_map_tree(
  outer : @tree.Tree[T],
  f : (T) -> Gen[U],
  size : Int32,
  inner_seed : UInt64,
) -> @tree.Tree[U]? {
  match f(outer.value).run(size, @rng.Rng::new(inner_seed)) {
    None =>
      // The inner generator declined for this outer value, so shrinking here
      // would produce a value the pipeline cannot build. Propagate the
      // discard instead of inventing a node.
      None
    Some(inner) =>
      Some(
        @tree.Tree::lazy_node(inner.value, fn() {
          let out : Array[@tree.Tree[U]] = []
          for child in outer.children() {
            match flat_map_tree(child, f, size, inner_seed) {
              None => ()
              Some(tree) => out.push(tree)
            }
          }
          for child in inner.children() {
            out.push(child)
          }
          out
        }),
      )
  }
}

///|
/// Combines two generators, shrinking either side while holding the other.
pub fn[T, U, V] Gen::zip_with(
  self : Gen[T],
  other : Gen[U],
  combine : (T, U) -> V,
) -> Gen[V] {
  Gen::new(fn(size, rng) {
    match self.run(size, rng) {
      None => None
      Some(left) =>
        match other.run(size, rng) {
          None => None
          Some(right) => Some(left.zip_with(right, combine))
        }
    }
  })
}

///|
/// Pairs two generators.
pub fn[T, U] Gen::zip(self : Gen[T], other : Gen[U]) -> Gen[(T, U)] {
  self.zip_with(other, (a, b) => (a, b))
}

///|
/// Lets a generator read the current size, which grows over the course of a
/// run so that early cases stay small and readable.
pub fn[T] Gen::sized(create : (Int32) -> Gen[T]) -> Gen[T] {
  Gen::new(fn(size, rng) { create(size).run(size, rng) })
}

///|
/// Runs a generator at a fixed size regardless of the run's schedule.
pub fn[T] Gen::resize(self : Gen[T], size : Int32) -> Gen[T] {
  Gen::new(fn(_, rng) { self.run(size, rng) })
}

///|
/// Rescales the size before running the generator.
pub fn[T] Gen::scale(self : Gen[T], f : (Int32) -> Int32) -> Gen[T] {
  Gen::new(fn(size, rng) { self.run(f(size), rng) })
}

///|
/// Rejects draws that fail `pred`, retrying up to `attempts` times.
///
/// Retrying happens at generation time and pruning at shrink time, so a
/// counterexample reported for a filtered generator is guaranteed to satisfy
/// the predicate. If every attempt is rejected the draw becomes a discard.
pub fn[T] Gen::filter(
  self : Gen[T],
  pred : (T) -> Bool,
  attempts~ : Int32 = 100,
) -> Gen[T] {
  Gen::new(fn(size, rng) {
    let mut found : @tree.Tree[T]? = None
    let mut tries = 0
    while found is None && tries < attempts {
      match self.run(size, rng) {
        None => ()
        Some(tree) => if pred(tree.value) { found = Some(tree) }
      }
      tries = tries + 1
    }
    found.map(t => t.filter(pred))
  })
}

///|
/// Chooses uniformly among the supplied generators.
pub fn[T] Gen::one_of(generators : Array[Gen[T]]) -> Gen[T] {
  Gen::new(fn(size, rng) {
    if generators.is_empty() {
      None
    } else {
      let index = rng.next_below(generators.length().reinterpret_as_uint())
      generators[index.reinterpret_as_int()].run(size, rng)
    }
  })
}

///|
/// Chooses among the supplied generators in proportion to their weights.
pub fn[T] frequency(weighted : Array[(Int32, Gen[T])]) -> Gen[T] {
  Gen::new(fn(size, rng) {
    let mut total = 0
    for entry in weighted {
      let (weight, _) = entry
      if weight > 0 {
        total = total + weight
      }
    }
    if total <= 0 {
      None
    } else {
      let mut ticket = rng
        .next_below(total.reinterpret_as_uint())
        .reinterpret_as_int()
      let mut chosen : @tree.Tree[T]? = None
      for entry in weighted {
        let (weight, generator) = entry
        if chosen is None && weight > 0 {
          if ticket < weight {
            chosen = generator.run(size, rng)
          }
          ticket = ticket - weight
        }
      }
      chosen
    }
  })
}

///|
/// Draws a fair coin.
pub fn bool() -> Gen[Bool] {
  Gen::new(fn(_, rng) { Some(@tree.Tree::singleton(rng.next_bool())) })
}

///|
/// Shrinks `value` towards `target`, yielding a halving sequence.
///
/// The candidates are ordered smallest-first so that a greedy search can jump
/// straight to the boundary of the failure instead of creeping down one step
/// at a time. For `value = 10`, `target = 0` the candidates are
/// `[0, 5, 8, 9]`: if 0 still fails the property the search stops immediately,
/// and otherwise it converges on the true boundary in a logarithmic number of
/// steps.
pub fn shrink_towards(value : Int32, target : Int32) -> Array[Int32] {
  let out : Array[Int32] = []
  if value == target {
    return out
  }
  out.push(target)
  let difference = value - target
  let magnitude = if difference < 0 { -difference } else { difference }
  let direction = if difference < 0 { -1 } else { 1 }
  let mut step = magnitude
  while step > 1 {
    step = step / 2
    let candidate = value - direction * step
    if candidate != target {
      out.push(candidate)
    }
  }
  out
}

///|
fn int_tree(value : Int32, low : Int32) -> @tree.Tree[Int32] {
  @tree.Tree::lazy_node(value, fn() {
    shrink_towards(value, low).map(v => int_tree(v, low))
  })
}

///|
/// Draws an integer from the half-open range `[low, high)` and shrinks it
/// towards `low`.
pub fn int_range(low : Int32, high : Int32) -> Gen[Int32] {
  Gen::new(fn(_, rng) {
    if high <= low {
      Some(int_tree(low, low))
    } else {
      let width = (high - low).reinterpret_as_uint()
      let offset = rng.next_below(width).reinterpret_as_int()
      Some(int_tree(low + offset, low))
    }
  })
}

///|
/// Draws an integer from `[-size, size]`, shrinking towards zero.
///
/// Bounding by the run's size is deliberate: an unconstrained full-range `Int`
/// produces counterexamples like `-1893742519` that say nothing to a reader,
/// while `[-size, size]` starts small and still reaches interesting magnitudes
/// as the run progresses.
pub fn int() -> Gen[Int32] {
  Gen::sized(size => int_range(-size, size + 1))
}

///|
/// Draws a printable ASCII character, shrinking towards a space.
pub fn char() -> Gen[Char] {
  int_range(32, 127).map(code => code.unsafe_to_char())
}

///|
/// Draws a string of printable characters, shrinking both its contents and its
/// length.
pub fn string() -> Gen[String] {
  char()
  .array_of()
  .map(codes => {
    let mut text = ""
    for code in codes {
      text = text + code.to_string()
    }
    text
  })
}

///|
/// Draws `count` trees from a generator, propagating a refusal.
fn[T] draw_trees(
  generator : Gen[T],
  count : Int32,
  size : Int32,
  rng : @rng.Rng,
) -> Array[@tree.Tree[T]]? {
  let elements : Array[@tree.Tree[T]] = []
  let mut index = 0
  let mut failed = false
  while index < count && !failed {
    match generator.run(size, rng) {
      None => failed = true
      Some(tree) => elements.push(tree)
    }
    index = index + 1
  }
  if failed {
    None
  } else {
    Some(elements)
  }
}

///|
/// Draws exactly `count` values.
///
/// The length is fixed by the caller, so shrinking only simplifies elements.
/// Offering shorter arrays here would break the guarantee the function name
/// makes, and a property that relied on it would start seeing counterexamples
/// the generator claimed it could not produce.
pub fn[T] Gen::array_with_size(self : Gen[T], count : Int32) -> Gen[Array[T]] {
  Gen::new(fn(size, rng) {
    draw_trees(self, count, size, rng).map(elements => {
      array_tree(elements, false)
    })
  })
}

///|
/// Draws an array whose length is itself generated from `[0, size]`.
///
/// Here the length is part of the generated value, so shrinking shortens the
/// array as well as simplifying its elements.
pub fn[T] Gen::array_of(self : Gen[T]) -> Gen[Array[T]] {
  Gen::sized(fn(size) {
    Gen::new(fn(_, rng) {
      let bound = if size < 0 { 0 } else { size }
      let count = rng
        .next_below((bound + 1).reinterpret_as_uint())
        .reinterpret_as_int()
      draw_trees(self, count, size, rng).map(elements => {
        array_tree(elements, true)
      })
    })
  })
}

///|
fn[T] take(xs : Array[T], count : Int32) -> Array[T] {
  let out : Array[T] = []
  for i in 0..<count {
    out.push(xs[i])
  }
  out
}

///|
/// Builds a shrink tree for an array from the trees of its elements.
///
/// Two families of simplification are offered, structure first: dropping the
/// back half and dropping the last element, then simplifying individual
/// elements in place. Offering structural cuts before element tweaks is what
/// makes a failing 100-element array shrink to a 2-element one instead of to a
/// 100-element array of zeros.
fn[T] array_tree(
  elements : Array[@tree.Tree[T]],
  allow_shorter : Bool,
) -> @tree.Tree[Array[T]] {
  let values = elements.map(e => e.value)
  @tree.Tree::lazy_node(values, fn() {
    let out : Array[@tree.Tree[Array[T]]] = []
    let count = elements.length()
    if allow_shorter && count > 0 {
      out.push(array_tree(take(elements, count / 2), allow_shorter))
      out.push(array_tree(take(elements, count - 1), allow_shorter))
    }
    for i in 0..<count {
      for child in elements[i].children() {
        let copy = elements.copy()
        copy[i] = child
        out.push(array_tree(copy, allow_shorter))
      }
    }
    out
  })
}

///|
/// Draws an `Option`, shrinking `Some(x)` towards `None` before shrinking `x`.
pub fn[T] Gen::option_of(self : Gen[T]) -> Gen[T?] {
  Gen::new(fn(size, rng) {
    if rng.next_below(2U) == 0U {
      Some(@tree.Tree::singleton(None))
    } else {
      match self.run(size, rng) {
        None => None
        Some(tree) =>
          Some(
            @tree.Tree::lazy_node(Some(tree.value), fn() {
              let out : Array[@tree.Tree[T?]] = [@tree.Tree::singleton(None)]
              for child in tree.children() {
                out.push(child.map(v => Some(v)))
              }
              out
            }),
          )
      }
    }
  })
}

///|
/// Draws a `Result`, shrinking the error side towards `Ok`.
pub fn[T, E] Gen::result_of(ok : Gen[T], err : Gen[E]) -> Gen[Result[T, E]] {
  Gen::new(fn(size, rng) {
    if rng.next_below(3U) == 0U {
      match err.run(size, rng) {
        None => None
        Some(tree) => Some(tree.map(e => Err(e)))
      }
    } else {
      match ok.run(size, rng) {
        None => None
        Some(tree) => Some(tree.map(v => Ok(v)))
      }
    }
  })
}

///|
/// Draws a value once, using a fixed seed and size. Useful in tests that pin
/// generator behaviour and in documentation examples.
pub fn[T] Gen::sample(
  self : Gen[T],
  seed~ : UInt64 = 37,
  size~ : Int32 = 30,
) -> T? {
  self.run(size, @rng.Rng::new(seed)).map(t => t.value)
}

///|
/// Draws `count` values, each from its own derived seed.
pub fn[T] Gen::samples(
  self : Gen[T],
  count~ : Int32 = 10,
  seed~ : UInt64 = 37,
  size~ : Int32 = 30,
) -> Array[T] {
  let out : Array[T] = []
  for i in 0..<count {
    match self.run(size, @rng.Rng::new(@rng.derive_seed(seed, i))) {
      None => ()
      Some(tree) => out.push(tree.value)
    }
  }
  out
}

///|
test "the same seed always yields the same sample" {
  let first = int_range(0, 1000).samples(count=20, seed=99UL)
  let second = int_range(0, 1000).samples(count=20, seed=99UL)
  assert_eq(first, second)
  let other = int_range(0, 1000).samples(count=20, seed=100UL)
  assert_true(first != other)
}

///|
test "int_range honours its bounds" {
  let values = int_range(-7, 8).samples(count=500, size=50, seed=5UL)
  for v in values {
    assert_true(v >= -7 && v < 8)
  }
}

///|
test "int_range shrinks towards its lower bound" {
  // A run that draws 87 from [0, 100) must be able to offer 0 first.
  let gen = int_range(0, 100)
  let tree = gen.run(100, @rng.Rng::new(1UL)).unwrap()
  let path = tree.follow([0]).unwrap()
  assert_eq(path.value, 0)
}

///|
test "shrink_towards is ordered smallest first and skips the target twice" {
  assert_eq(shrink_towards(10, 0), [0, 5, 8, 9])
  assert_eq(shrink_towards(0, 0), [])
  assert_eq(shrink_towards(-10, 0), [0, -5, -8, -9])
  assert_eq(shrink_towards(1, 0), [0])
}

///|
test "map keeps the shrink tree and transforms every node" {
  let gen = int_range(1, 10).map(x => x * 2)
  let tree = gen.run(10, @rng.Rng::new(3UL)).unwrap()
  assert_eq(tree.value % 2, 0)
  // The first shrink candidate is the mapped lower bound.
  assert_eq(tree.follow([0]).unwrap().value, 2)
}

///|
test "flat_map shrinks the value that chose the shape" {
  // Length is generated, then an array of exactly that length. Shrinking the
  // length must produce a genuinely shorter array — the case a per-type
  // shrinker cannot reach, because it only ever sees the finished array.
  let gen = int_range(3, 9).flat_map(n => Gen::pure(()).array_with_size(n))
  let tree = gen.run(10, @rng.Rng::new(8UL)).unwrap()
  assert_true(tree.value.length() >= 3)
  let lengths = tree.children().map(c => c.value.length())
  // The outer value shrinks towards 3, so at least one child is shorter.
  assert_true(lengths.any(l => l < tree.value.length()))
}

///|
test "flat_map re-derives the inner generator for every outer shrink" {
  // The pin is exact: the children of the combined tree must be the outer
  // generator's own shrink candidates, each re-derived into an array of that
  // length. If shrinking merely replayed the inner tree, every child would
  // carry the original length instead.
  let gen = int_range(4, 10).flat_map(n => Gen::pure(false).array_with_size(n))
  let mut longer = 0
  for index in 0..<20 {
    let seed = @rng.derive_seed(3UL, index)
    let tree = gen.run(10, @rng.Rng::new(seed)).unwrap()
    let length = tree.value.length()
    assert_eq(
      tree.children().map(c => c.value.length()),
      shrink_towards(length, 4),
    )
    if length > 4 {
      longer = longer + 1
    }
  }
  assert_true(longer > 0)
}

///|
test "array_with_size keeps a fixed length while shrinking elements" {
  let gen = int_range(0, 100).array_with_size(5)
  let tree = gen.run(100, @rng.Rng::new(4UL)).unwrap()
  assert_eq(tree.value.length(), 5)
  for child in tree.children() {
    assert_eq(child.value.length(), 5)
  }
  // But a shrunk element is smaller than the original.
  assert_true(tree.children().any(c => c.value[0] < tree.value[0]))
}

///|
test "array_of shrinks length before contents" {
  let gen = int_range(0, 1000).array_of()
  let tree = gen.run(40, @rng.Rng::new(2UL)).unwrap()
  let children = tree.children()
  assert_true(children.length() > 0)
  // The very first candidate is a structural cut, never a single element tweak.
  let first_len = children[0].value.length()
  assert_true(first_len < tree.value.length() || tree.value.length() <= 1)
}

///|
test "filter rejects unsatisfiable draws instead of lying" {
  // Odd values only, from an even-only source: every attempt is rejected.
  let impossible = Gen::pure(2).filter(x => x % 2 == 1, attempts=5)
  assert_true(impossible.sample(seed=1UL) is None)
}

///|
test "filter keeps satisfying values and prunes offenders from the tree" {
  let evens = int_range(0, 100).filter(x => x % 2 == 0)
  let values = evens.samples(count=50, size=100, seed=6UL)
  assert_true(values.length() > 0)
  for v in values {
    assert_eq(v % 2, 0)
  }
}

///|
test "option_of shrinks Some towards None first" {
  // Roughly a third of draws are `None`, so scan a few seeds for a `Some`
  // root rather than betting the test on one.
  let gen = int_range(10, 20).option_of()
  let mut checked = 0
  for index in 0..<40 {
    let seed = @rng.derive_seed(7UL, index)
    match gen.run(20, @rng.Rng::new(seed)) {
      None => ()
      Some(tree) =>
        match tree.value {
          None => ()
          Some(_) => {
            assert_eq(tree.children()[0].value, None)
            checked = checked + 1
          }
        }
    }
  }
  assert_true(checked > 0)
}

///|
test "one_of only draws from the supplied generators" {
  let gen = Gen::one_of([Gen::pure(1), Gen::pure(2), Gen::pure(3)])
  let values = gen.samples(count=100, seed=17UL)
  for v in values {
    assert_true(v >= 1 && v <= 3)
  }
}

///|
test "frequency respects zero weight" {
  let gen = frequency([(0, Gen::pure(1)), (1, Gen::pure(2))])
  let values = gen.samples(count=50, seed=18UL)
  for v in values {
    assert_eq(v, 2)
  }
}

///|
test "string shrinks towards the empty string" {
  let gen = string()
  let tree = gen
    .filter(s => s.length() > 3)
    .run(20, @rng.Rng::new(21UL))
    .unwrap()
  assert_true(tree.value.length() > 3)
  // A structural cut is available and yields something shorter.
  assert_true(tree.children().any(c => c.value.length() < tree.value.length()))
}

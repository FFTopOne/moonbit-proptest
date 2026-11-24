///|
/// The default seed. Deterministic on purpose: a run that fails today must
/// fail tomorrow at the same counterexample, and a random default would turn
/// every real defect into a flaky test.
pub const DEFAULT_SEED : UInt64 = 0x5EED2026UL

///|
/// How a run is executed.
pub struct Config {
  /// Number of cases to draw.
  count : Int32
  /// Largest size handed to the generator; the actual size ramps up from 0.
  max_size : Int32
  /// Base seed. Cases derive their seeds from it, so one number reproduces a
  /// whole run.
  seed : UInt64
  /// Cap on accepted shrink steps.
  max_steps : Int32
  /// Cap on shrink candidates examined.
  max_attempts : Int32
  /// How many refused draws are tolerated before the run gives up.
  discard_limit : Int32
}

///|
pub fn Config::new(
  count~ : Int32 = 100,
  max_size~ : Int32 = 100,
  seed~ : UInt64 = DEFAULT_SEED,
  max_steps~ : Int32 = 100,
  max_attempts~ : Int32 = 1000,
  discard_limit~ : Int32 = 100,
) -> Config {
  { count, max_size, seed, max_steps, max_attempts, discard_limit, }
}

///|
/// Everything a run produced.
///
/// Failures carry a rendered cause rather than a raised value. Property code
/// raises a wide variety of error types — assertion failures, custom
/// `suberror`s, library errors — and unifying them at `Error` forces every
/// caller to handle a type it cannot inspect. A message is what a reader
/// actually needs, and it keeps `Outcome` free of a parameter it does not use.
pub enum Outcome[T] {
  /// Every case held.
  Passed(tests~ : Int32, discarded~ : Int32)
  /// Too many generators refused to produce a value for this run to mean
  /// anything. Usually an over-constrained `filter`.
  GaveUp(tests~ : Int32, discarded~ : Int32)
  /// A case failed. `counterexample` is the simplified value, not the value
  /// that was originally drawn.
  Falsified(
    counterexample~ : T,
    cause~ : String?,
    case_seed~ : UInt64,
    size~ : Int32,
    path~ : Array[Int32],
    tests~ : Int32,
    discarded~ : Int32,
    steps~ : Int32,
    attempts~ : Int32,
    truncated~ : Bool
  )
}

///|
/// Enough information to reproduce one case exactly.
///
/// Note what is *not* stored: the run's base seed, its case count, or its size
/// schedule. Recording the derived case seed and the size it ran at makes a
/// replay independent of the configuration, so a counterexample stays
/// reproducible after somebody raises `count` or lowers `max_size`.
pub struct Replay {
  case_seed : UInt64
  size : Int32
  path : Array[Int32]
}

///|
/// The size handed to case `index` of a run of `count` cases.
pub fn size_at(index : Int32, count : Int32, max_size : Int32) -> Int32 {
  if count <= 1 {
    0
  } else {
    index * max_size / (count - 1)
  }
}

///|
/// Runs `fails` over a value. Kept as a named function so the shrinker's
/// predicate reads as the question it actually asks: does this candidate still
/// fail.
fn[T] probe(fails : (T) -> String?, value : T) -> String? {
  fails(value)
}

///|
/// Runs an assertion-style property and renders whatever it raised.
///
/// Written in the postfix form `expr catch { ... } noraise { ... }`, which
/// keeps the two outcomes explicit: the `catch` arm sees the raised value and
/// the `noraise` arm only runs when nothing was raised.
fn[T] probe_raise(property : (T) -> Unit raise Error, value : T) -> String? {
  let slot : Array[String?] = [None]
  try property(value) catch {
    cause => slot[0] = Some(cause.to_string())
  } noraise {
    _ => ()
  }
  slot[0]
}

///|
/// The shared driver. One scheduler, one shrinker and one report serve both
/// public entry points; they differ only in how a case is judged.
fn[T] run(
  generator : @gen.Gen[T],
  fails : (T) -> String?,
  config : Config,
) -> Outcome[T] {
  let mut tests = 0
  let mut discarded = 0
  let mut result : Outcome[T]? = None
  let mut index = 0
  while result is None && index < config.count {
    let case_seed = @rng.derive_seed(config.seed, index)
    let size = size_at(index, config.count, config.max_size)
    match generator.run(size, @rng.Rng::new(case_seed)) {
      None => {
        discarded = discarded + 1
        if discarded > config.discard_limit {
          result = Some(GaveUp(tests~, discarded~))
        }
      }
      Some(tree) => {
        tests = tests + 1
        match fails(tree.value) {
          None => ()
          Some(_) => {
            let shrunk = @shrink.shrink(
              tree,
              value => probe(fails, value) is Some(_),
              max_steps=config.max_steps,
              max_attempts=config.max_attempts,
            )
            result = Some(
              Falsified(
                counterexample=shrunk.value,
                cause=probe(fails, shrunk.value),
                case_seed~,
                size~,
                path=shrunk.path,
                tests~,
                discarded~,
                steps=shrunk.steps,
                attempts=shrunk.attempts,
                truncated=shrunk.truncated,
              ),
            )
          }
        }
      }
    }
    index = index + 1
  }
  match result {
    Some(outcome) => outcome
    // A run that never managed to judge a single case proves nothing. Reporting
    // it as `Passed` would be the worst possible answer: green, and meaningless.
    None =>
      if tests == 0 {
        GaveUp(tests~, discarded~)
      } else {
        Passed(tests~, discarded~)
      }
  }
}

///|
/// Checks that `holds` is true for every generated value.
///
/// Returns `Passed` when the whole run held, `Falsified` with the simplified
/// counterexample when some case did not, and `GaveUp` when the generator
/// refused too many draws for the result to mean anything.
pub fn[T] check(
  generator : @gen.Gen[T],
  holds : (T) -> Bool,
  config? : Config,
) -> Outcome[T] {
  let cfg = match config {
    None => Config::new()
    Some(c) => c
  }
  run(
    generator,
    // An empty message means "failed, nothing to add". A boolean predicate has
    // no explanation to offer, and printing a placeholder would bury the
    // counterexample under noise.
    value => if holds(value) { None } else { Some("") },
    cfg,
  )
}

///|
/// Checks a property written with assertions.
///
/// A raised error counts as a failure, which is what makes ordinary
/// `assert_eq` usable inside a property: the assertion that blew up is already
/// the explanation, and the shrinker hands back the smallest input that still
/// blows it up.
pub fn[T] check_raise(
  generator : @gen.Gen[T],
  property : (T) -> Unit raise Error,
  config? : Config,
) -> Outcome[T] {
  let cfg = match config {
    None => Config::new()
    Some(c) => c
  }
  run(generator, value => probe_raise(property, value), cfg)
}

///|
/// Recomputes the value a `Falsified` outcome shrank to, from the case seed and
/// shrink path alone.
///
/// This is what makes a report actionable: it does not trust the stored
/// counterexample, it regenerates it. If a generator changed such that the old
/// path no longer exists, replay returns `None` rather than silently reporting
/// a value the current code can no longer produce.
pub fn[T] replay(generator : @gen.Gen[T], record : Replay) -> T? {
  match generator.run(record.size, @rng.Rng::new(record.case_seed)) {
    None => None
    Some(tree) => tree.follow(record.path).map(node => node.value)
  }
}

///|
/// Extracts the replay record from a failing outcome.
pub fn[T] Outcome::to_replay(self : Outcome[T]) -> Replay? {
  match self {
    Passed(..) => None
    GaveUp(..) => None
    Falsified(case_seed~, size~, path~, ..) => Some({ case_seed, size, path, })
  }
}

///|
/// Renders a shrink path as `[0, 2, 1]`.
pub fn format_path(path : Array[Int32]) -> String {
  let mut text = "["
  for i in 0..<path.length() {
    if i > 0 {
      text = text + ", "
    }
    text = text + path[i].to_string()
  }
  text + "]"
}

///|
/// Formats an outcome for a human, using `show` for the counterexample.
pub fn[T] Outcome::describe(self : Outcome[T], show : (T) -> String) -> String {
  match self {
    Passed(tests~, discarded~) =>
      "PASSED: \{tests} cases held, \{discarded} discarded"
    GaveUp(tests~, discarded~) =>
      "GAVE UP: \{discarded} draws were refused after \{tests} cases. The generator is over-constrained; loosen its filter or raise the discard limit."
    Falsified(
      counterexample~,
      cause~,
      case_seed~,
      size~,
      path~,
      tests~,
      discarded~,
      steps~,
      attempts~,
      truncated~
    ) => {
      let mut report = "FAILED after \{tests} cases (\{discarded} discarded)\n"
      report = report + "  counterexample : \{show(counterexample)}\n"
      let seed_text = case_seed.to_string(radix=16)
      let replay_text = "  replay         : seed=0x\{seed_text} size=\{size} path=\{format_path(path)}\n"
      report = report + replay_text
      report = report +
        "  shrinking      : \{steps} steps over \{attempts} candidates"
      let tail = if truncated {
        " (budget exhausted; a smaller example may exist)"
      } else {
        " (locally minimal)"
      }
      report = report + tail + "\n"
      match cause {
        None => report
        Some(message) =>
          if message == "" {
            report
          } else {
            report + "  raised         : \{message}\n"
          }
      }
    }
  }
}

///|
/// Like `describe`, using the type's `Debug` instance for the counterexample.
pub fn[T : @debug.Debug] Outcome::describe_with_debug(
  self : Outcome[T],
) -> String {
  self.describe(fn(value) { @debug.render(@debug.Debug::to_repr(value)) })
}

///|
test "a property that holds passes every case" {
  let outcome = check(
    @gen.int_range(0, 100),
    x => x >= 0,
    config=Config::new(count=200),
  )
  match outcome {
    Passed(tests~, discarded~) => {
      assert_eq(tests, 200)
      assert_eq(discarded, 0)
    }
    _ => abort("expected the property to hold")
  }
}

///|
test "a failing property reports the exact boundary, not the original draw" {
  // Five is the smallest integer >= 5, and the run must land on it no matter
  // which value it happened to draw first.
  let outcome = check(
    @gen.int_range(0, 100),
    x => x < 5,
    config=Config::new(count=300, max_size=100, seed=1234UL),
  )
  match outcome {
    Falsified(counterexample~, steps~, ..) => {
      assert_eq(counterexample, 5)
      assert_true(steps > 0)
    }
    _ => abort("expected the property to fail")
  }
}

///|
test "a raised assertion is captured with its message" {
  let outcome = check_raise(
    @gen.int_range(0, 50),
    x => if x > 3 { assert_eq(x, 3) },
    config=Config::new(count=100, seed=7UL),
  )
  match outcome {
    Falsified(counterexample~, cause~, ..) => {
      // The smallest x above 3 is 4, and the shrinker must find it.
      assert_eq(counterexample, 4)
      assert_true(cause is Some(_))
    }
    _ => abort("expected the assertion to be caught")
  }
}

///|
test "replay regenerates the counterexample from the seed and path alone" {
  let generator = @gen.int_range(0, 500)
  let outcome = check(
    generator,
    x => x < 87,
    config=Config::new(count=200, seed=99UL),
  )
  let record = outcome.to_replay().unwrap()
  assert_eq(replay(generator, record).unwrap(), 87)
  match outcome {
    Falsified(counterexample~, ..) =>
      assert_eq(replay(generator, record).unwrap(), counterexample)
    _ => abort("expected a failure")
  }
}

///|
test "replay refuses a path the current generator cannot produce" {
  let generator = @gen.int_range(0, 10)
  let bogus : Replay = { case_seed: 1UL, size: 10, path: [9, 9, 9], }
  assert_true(replay(generator, bogus) is None)
}

///|
test "an impossible generator gives up instead of reporting a fake failure" {
  let impossible = @gen.Gen::pure(2).filter(x => x % 2 == 1, attempts=3)
  let outcome = check(impossible, _ => false, config=Config::new(count=10))
  match outcome {
    GaveUp(..) => ()
    _ => abort("expected GaveUp")
  }
}

///|
test "the same config always produces the same counterexample" {
  let run_once = fn() {
    match
      check(
        @gen.int_range(0, 60).array_of(),
        xs => xs.length() < 3,
        config=Config::new(count=100, seed=555UL),
      ) {
      Falsified(counterexample~, ..) => counterexample
      _ => abort("expected a failure")
    }
  }
  assert_eq(run_once(), run_once())
}

///|
test "size ramps up across the run" {
  assert_eq(size_at(0, 100, 100), 0)
  assert_eq(size_at(99, 100, 100), 100)
  assert_eq(size_at(0, 1, 100), 0)
}

///|
test "describe reports the seed and path needed to reproduce" {
  let outcome = check(
    @gen.int_range(0, 20),
    x => x < 3,
    config=Config::new(count=50, seed=42UL),
  )
  let text = outcome.describe_with_debug()
  assert_true(text.contains("FAILED"))
  assert_true(text.contains("replay"))
  assert_true(text.contains("counterexample"))
  assert_true(text.contains("0x"))
}

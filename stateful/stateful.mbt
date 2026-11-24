///|
/// A model of a stateful system under test.
///
/// `S` is the model state and `C` the command type. The model is a plain value
/// that can be evolved with `apply` without touching the real system, which is
/// what lets a sequence be reasoned about, shrunk, and replayed.
///
/// The real system is captured by the closures, not passed in: `execute`
/// performs a command against it, `reset` returns it to a known state before
/// each attempt, and `verify` compares it against the model. Keeping the system
/// out of the type parameters means this works equally well for an in-memory
/// data structure, a file, and a server reached over a socket.
pub struct Machine[S, C] {
  /// The model state before any command runs.
  initial : S
  /// Returns the real system to its initial state.
  ///
  /// Required because a property is run many times, and again once per shrink
  /// candidate. Without it, the second attempt would observe the leftovers of
  /// the first and the search would chase ghosts.
  reset : () -> Unit raise Error
  /// Draws a command that is legal in `S`.
  ///
  /// Commands are generated against the model state rather than the real
  /// system, which is the only way to guarantee the sequence is well formed
  /// before anything has been executed.
  generate : (S) -> @gen.Gen[C]
  /// Advances the model.
  apply : (S, C) -> S
  /// Whether a command is legal in a given model state.
  ///
  /// Deleting a command from a sequence can leave later commands without the
  /// state they expected. Those are skipped at run time rather than executed
  /// blindly, so a shrunk sequence stays meaningful instead of failing for a
  /// reason that has nothing to do with the original defect.
  precondition : (S, C) -> Bool
  /// Performs the command on the real system.
  execute : (C) -> Unit raise Error
  /// Asserts that the real system still agrees with the model.
  verify : (S) -> Unit raise Error
}

///|
pub fn[S, C] Machine::new(
  initial~ : S,
  reset~ : () -> Unit raise Error,
  generate~ : (S) -> @gen.Gen[C],
  apply~ : (S, C) -> S,
  precondition~ : (S, C) -> Bool,
  execute~ : (C) -> Unit raise Error,
  verify~ : (S) -> Unit raise Error,
) -> Machine[S, C] {
  { initial, reset, generate, apply, precondition, execute, verify, }
}

///|
/// A command paired with the shrink tree it was drawn from.
///
/// Keeping the tree alongside the value is what allows a single command to be
/// simplified later without re-running the whole dependent generation.
priv struct Drawn[C] {
  command : C
  tree : @tree.Tree[C]
}

///|
/// Draws `remaining` commands, each against the state the previous ones lead
/// to.
fn[S, C] draw(
  machine : Machine[S, C],
  state : S,
  remaining : Int32,
  size : Int32,
  seed : UInt64,
) -> Array[Drawn[C]]? {
  if remaining <= 0 {
    return Some(([] : Array[Drawn[C]]))
  }
  let legal = (machine.generate)(state).filter(fn(command) {
    (machine.precondition)(state, command)
  })
  match legal.run(size, @rng.Rng::new(seed)) {
    None => None
    Some(tree) =>
      match
        draw(
          machine,
          (machine.apply)(state, tree.value),
          remaining - 1,
          size,
          @rng.derive_seed(seed, 1),
        ) {
        None => None
        Some(rest) => {
          let out : Array[Drawn[C]] = [{ command: tree.value, tree, }]
          for item in rest {
            out.push(item)
          }
          Some(out)
        }
      }
  }
}

///|
fn[C] commands_of(drawn : Array[Drawn[C]]) -> Array[C] {
  let out : Array[C] = []
  for item in drawn {
    out.push(item.command)
  }
  out
}

///|
fn[C] without(drawn : Array[Drawn[C]], index : Int32) -> Array[Drawn[C]] {
  let out : Array[Drawn[C]] = []
  for i in 0..<drawn.length() {
    if i != index {
      out.push(drawn[i])
    }
  }
  out
}

///|
fn[C] prefix(drawn : Array[Drawn[C]], count : Int32) -> Array[Drawn[C]] {
  let out : Array[Drawn[C]] = []
  for i in 0..<count {
    out.push(drawn[i])
  }
  out
}

///|
fn[C] replacing(
  drawn : Array[Drawn[C]],
  index : Int32,
  replacement : C,
) -> Array[Drawn[C]] {
  let out : Array[Drawn[C]] = []
  for i in 0..<drawn.length() {
    if i == index {
      out.push({ command: replacement, tree: drawn[i].tree, })
    } else {
      out.push(drawn[i])
    }
  }
  out
}

///|
/// Builds a shrink tree over a drawn sequence.
///
/// Offered in this order:
///
/// 1. **Delete one command, at any position.** Every index is its own child, so
///    a redundant command in the middle is reachable directly. Deleting only
///    the head would force the search to delete everything before it first, and
///    a greedy search refuses to take a step that stops the failure.
/// 2. **Cut the sequence in half.** A cheap way to make large jumps early.
/// 3. **Simplify one command in place**, keeping the rest.
///
/// Deletions come first because a reader wants the shortest failing sequence,
/// not the same length with duller commands. Every candidate stays legal:
/// commands whose precondition no longer holds are skipped when the sequence
/// runs, so a deletion can never produce a sequence that fails merely because
/// it is ill-formed.
fn[C] sequence_tree(drawn : Array[Drawn[C]]) -> @tree.Tree[Array[C]] {
  @tree.Tree::lazy_node(commands_of(drawn), fn() {
    let out : Array[@tree.Tree[Array[C]]] = []
    let count = drawn.length()
    for index in 0..<count {
      out.push(sequence_tree(without(drawn, index)))
    }
    if count > 1 {
      out.push(sequence_tree(prefix(drawn, count / 2)))
    }
    for index in 0..<count {
      for child in drawn[index].tree.children() {
        out.push(sequence_tree(replacing(drawn, index, child.value)))
      }
    }
    out
  })
}

///|
/// Draws a command sequence whose length is at most `size`.
pub fn[S, C] Machine::sequence(self : Machine[S, C]) -> @gen.Gen[Array[C]] {
  @gen.Gen::sized(fn(size) {
    @gen.Gen::new(fn(_, rng) {
      let bound = if size < 0 { 0 } else { size }
      let count = rng
        .next_below((bound + 1).reinterpret_as_uint())
        .reinterpret_as_int()
      match draw(self, self.initial, count, size, rng.next_uint64()) {
        None => None
        Some(drawn) => Some(sequence_tree(drawn))
      }
    })
  })
}

///|
/// Runs a command sequence against the real system, checking the model after
/// every step.
///
/// Verifying after each command rather than only at the end is what makes the
/// reported sequence short: the first disagreement is the one the shrinker
/// then minimises towards.
pub fn[S, C] Machine::run_sequence(
  self : Machine[S, C],
  commands : Array[C],
) -> Unit raise Error {
  (self.reset)()
  let mut state = self.initial
  for command in commands {
    if (self.precondition)(state, command) {
      (self.execute)(command)
      state = (self.apply)(state, command)
      (self.verify)(state)
    }
  }
}

///|
/// Checks a state machine, reporting the shortest failing command sequence.
///
/// The counterexample is an `Array[C]`, and shrinking removes commands as well
/// as simplifying them, so a defect reachable in three commands is reported as
/// three commands even if the run happened to generate ten.
pub fn[S, C] check_machine(
  machine : Machine[S, C],
  config? : @prop.Config,
) -> @prop.Outcome[Array[C]] {
  @prop.check_raise(
    machine.sequence(),
    commands => machine.run_sequence(commands),
    config?,
  )
}

///|
priv enum CounterCommand {
  Increment
  Decrement
  AddTo(Int32)
}

///|
/// A counter whose decrement path is missing its zero guard.
///
/// The model returns to zero; the implementation goes negative. One command is
/// enough to expose it, which makes this the case that proves a single-command
/// witness is reachable.
fn make_broken_counter(cell : Array[Int32]) -> Machine[Int32, CounterCommand] {
  Machine::new(
    initial=0,
    reset=fn() { cell[0] = 0 },
    generate=fn(_state) {
      @gen.frequency([
        (3, @gen.Gen::pure(Increment)),
        (3, @gen.Gen::pure(Decrement)),
      ])
    },
    apply=fn(state, command) {
      match command {
        Increment => state + 1
        Decrement => if state > 0 { state - 1 } else { 0 }
        AddTo(amount) => state + amount
      }
    },
    precondition=fn(_state, _command) { true },
    execute=fn(command) {
      match command {
        Increment => cell[0] = cell[0] + 1
        // The bug: no guard, so the counter can go below zero.
        Decrement => cell[0] = cell[0] - 1
        AddTo(amount) => cell[0] = cell[0] + amount
      }
    },
    verify=fn(state) raise {
      if cell[0] != state {
        raise Failure::Failure("model says \{state}, counter holds \{cell[0]}")
      }
    },
  )
}

///|
/// A counter whose cap is missing on the increment path only.
///
/// The model saturates at three; the implementation lets an increment exceed
/// it. Reaching the disagreement takes several commands, so this is the case
/// that exercises deleting commands rather than simplifying them.
fn make_capped_counter(cell : Array[Int32]) -> Machine[Int32, CounterCommand] {
  Machine::new(
    initial=0,
    reset=fn() { cell[0] = 0 },
    generate=fn(_state) {
      // Deliberately noise-heavy: most commands are model-neutral, so a
      // randomly drawn sequence is mostly padding around the two or three
      // commands that matter.
      @gen.frequency([
        (2, @gen.Gen::pure(Increment)),
        (5, @gen.Gen::pure(Decrement)),
        (5, @gen.int_range(0, 3).map(fn(amount) { AddTo(amount) })),
      ])
    },
    apply=fn(state, command) {
      match command {
        Increment => if state < 3 { state + 1 } else { 3 }
        Decrement => if state > 0 { state - 1 } else { 0 }
        AddTo(amount) => if state + amount < 3 { state + amount } else { 3 }
      }
    },
    precondition=fn(_state, _command) { true },
    execute=fn(command) {
      match command {
        // The bug: the cap is not enforced here.
        Increment => cell[0] = cell[0] + 1
        Decrement => if cell[0] > 0 { cell[0] = cell[0] - 1 }
        AddTo(amount) =>
          cell[0] = if cell[0] + amount < 3 { cell[0] + amount } else { 3 }
      }
    },
    verify=fn(state) raise {
      if cell[0] != state {
        raise Failure::Failure("model says \{state}, counter holds \{cell[0]}")
      }
    },
  )
}

///|
/// A counter whose implementation agrees with its model.
fn make_counter(cell : Array[Int32]) -> Machine[Int32, CounterCommand] {
  Machine::new(
    initial=0,
    reset=fn() { cell[0] = 0 },
    generate=fn(_state) {
      @gen.frequency([
        (3, @gen.Gen::pure(Increment)),
        (3, @gen.Gen::pure(Decrement)),
        (2, @gen.int_range(0, 4).map(fn(amount) { AddTo(amount) })),
      ])
    },
    apply=fn(state, command) {
      match command {
        Increment => state + 1
        Decrement => if state > 0 { state - 1 } else { 0 }
        AddTo(amount) => state + amount
      }
    },
    precondition=fn(_state, _command) { true },
    execute=fn(command) {
      match command {
        Increment => cell[0] = cell[0] + 1
        Decrement => if cell[0] > 0 { cell[0] = cell[0] - 1 }
        AddTo(amount) => cell[0] = cell[0] + amount
      }
    },
    verify=fn(state) raise {
      if cell[0] != state {
        raise Failure::Failure("model says \{state}, counter holds \{cell[0]}")
      }
    },
  )
}

///|
/// Renders a command sequence for reports.
fn show_commands(commands : Array[CounterCommand]) -> String {
  let mut text = "["
  for i in 0..<commands.length() {
    if i > 0 {
      text = text + ", "
    }
    let piece = match commands[i] {
      Increment => "Increment"
      Decrement => "Decrement"
      AddTo(amount) => "AddTo(\{amount})"
    }
    text = text + piece
  }
  text + "]"
}

///|
/// Runs the state-machine demo and returns a report, for the CLI.
pub fn demo_report() -> String {
  let cell = [0]
  let machine = make_capped_counter(cell)
  // Pinned at full length so the demo shows shrinking doing work: the first
  // failing case already carries ten commands, most of them padding.
  let outcome = @prop.check_raise(
    machine.sequence().resize(10),
    commands => machine.run_sequence(commands),
    config=@prop.Config::new(count=50, max_size=10, seed=2024UL),
  )
  let body = outcome.describe(show_commands)
  "### Capped counter: the cap is missing on increment\n\{body}"
}

///|
test "the honest counter passes" {
  let cell = [0]
  let outcome = check_machine(
    make_counter(cell),
    config=@prop.Config::new(count=200, max_size=12),
  )
  assert_true(outcome is @prop.Passed(_))
}

///|
test "the zero-guard bug is caught and shrunk to a single command" {
  let cell = [0]
  let outcome = check_machine(
    make_broken_counter(cell),
    config=@prop.Config::new(count=200, max_size=12, seed=2024UL),
  )
  match outcome {
    @prop.Falsified(counterexample~, ..) => {
      assert_eq(counterexample.length(), 1)
      assert_true(counterexample[0] is Decrement)
    }
    _ => abort("expected the broken counter to be caught")
  }
}

///|
test "the capped counter is reported without its padding commands" {
  // A disagreement needs either a fast path to two plus two increments, or four
  // increments: at most four commands. Sequences of up to ten are drawn, most
  // of them noise, so anything longer means deletion did not happen.
  let cell = [0]
  let outcome = check_machine(
    make_capped_counter(cell),
    config=@prop.Config::new(count=200, max_size=10, seed=2024UL),
  )
  match outcome {
    @prop.Falsified(counterexample~, steps~, ..) => {
      assert_true(counterexample.length() <= 4)
      assert_true(steps > 0)
    }
    _ => abort("expected the capped counter to be caught")
  }
}

///|
test "deleting any single command is reachable in one shrink step" {
  // The property of the tree that makes the search effective: from a sequence,
  // every index can be removed directly. If only the head were deletable, a
  // redundant command in the middle would be unreachable for a greedy search
  // that refuses steps where the property stops failing.
  let cell = [0]
  let machine = make_capped_counter(cell)
  let drawn = draw(machine, 0, 6, 6, 12345UL).unwrap()
  let tree = sequence_tree(drawn)
  let children = tree.children()
  // The first six children are the six single-command deletions, each exactly
  // one command shorter than the root.
  assert_true(children.length() >= 6)
  for index in 0..<6 {
    assert_eq(children[index].value.length(), 5)
  }
}

///|
test "the machine is reset between attempts" {
  // If `reset` were skipped the counter would keep its value across attempts
  // and the first command would appear to fail. Running the honest machine
  // twice proves the reset actually happens.
  let cell = [0]
  let machine = make_counter(cell)
  let first = check_machine(
    machine,
    config=@prop.Config::new(count=50, max_size=4, seed=11UL),
  )
  assert_true(first is @prop.Passed(_))
  let second = check_machine(
    machine,
    config=@prop.Config::new(count=50, max_size=4, seed=12UL),
  )
  assert_true(second is @prop.Passed(_))
}

///|
test "a shrunk sequence replays from its recorded path" {
  let cell = [0]
  let generator = make_capped_counter(cell).sequence()
  let outcome = check_machine(
    make_capped_counter(cell),
    config=@prop.Config::new(count=100, max_size=8, seed=31UL),
  )
  match outcome {
    @prop.Falsified(counterexample~, ..) => {
      let record = outcome.to_replay().unwrap()
      // Compared through the renderer rather than `assert_eq`: the command type
      // is private to this package, and deriving `Debug`/`Eq` on it only to
      // satisfy one assertion would widen the surface for no benefit.
      assert_eq(
        show_commands(@prop.replay(generator, record).unwrap()),
        show_commands(counterexample),
      )
    }
    _ => abort("expected a failure")
  }
}

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
  execute~ : (C) -> Unit raise Error,
  verify~ : (S) -> Unit raise Error,
) -> Machine[S, C] {
  { initial, reset, generate, apply, execute, verify, }
}

///|
/// Prepends a command to a generated suffix.
fn[C] cons(command : C, rest : Array[C]) -> Array[C] {
  let out : Array[C] = [command]
  for item in rest {
    out.push(item)
  }
  out
}

///|
/// Builds a sequence of up to `remaining` commands, each drawn against the
/// model state produced by the commands before it.
///
/// The dependent chain is expressed with `flat_map`, which buys sequence
/// shrinking for free: when the shrinker simplifies the first command it
/// re-derives the rest of the suffix from the new model state, so the shortened
/// sequence stays internally consistent instead of becoming a prefix that could
/// never have been generated.
fn[S, C] build(
  machine : Machine[S, C],
  state : S,
  remaining : Int32,
) -> @gen.Gen[Array[C]] {
  if remaining <= 0 {
    @gen.Gen::pure(([] : Array[C]))
  } else {
    (machine.generate)(state).flat_map(fn(command) {
      build(machine, (machine.apply)(state, command), remaining - 1).map(fn(
        rest,
      ) {
        cons(command, rest)
      })
    })
  }
}

///|
/// Generates command sequences whose length is drawn from `[0, size]`.
pub fn[S, C] Machine::sequence(self : Machine[S, C]) -> @gen.Gen[Array[C]] {
  @gen.Gen::sized(fn(size) {
    @gen.Gen::new(fn(_, rng) {
      let bound = if size < 0 { 0 } else { size }
      let count = rng
        .next_below((bound + 1).reinterpret_as_uint())
        .reinterpret_as_int()
      build(self, self.initial, count).run(size, rng)
    })
  })
}

///|
/// Runs a command sequence against the real system, checking the model after
/// every step.
///
/// Verifying after each command rather than only at the end is what makes the
/// reported sequence short: the first disagreement is what the shrinker then
/// minimises towards.
pub fn[S, C] Machine::run_sequence(
  self : Machine[S, C],
  commands : Array[C],
) -> Unit raise Error {
  (self.reset)()
  let mut state = self.initial
  for command in commands {
    (self.execute)(command)
    state = (self.apply)(state, command)
    (self.verify)(state)
  }
}

///|
/// Checks a state machine, reporting the shortest failing command sequence.
///
/// The counterexample is an `Array[C]`, and shrinking it removes commands as
/// well as simplifying them, so a bug reachable in three commands is reported
/// as three commands even if the run happened to generate twenty.
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
/// A deliberately broken "clamp at zero" counter.
///
/// The model says a decrement from zero stays at zero. The implementation
/// happily goes negative, which is exactly the kind of off-by-a-guard bug a
/// hand-written test misses and a model-based one finds immediately.
fn make_broken_counter(cell : Array[Int32]) -> Machine[Int32, CounterCommand] {
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
        raise CounterMismatch("model says \{state}, counter holds \{cell[0]}")
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
    execute=fn(command) {
      match command {
        Increment => cell[0] = cell[0] + 1
        Decrement => if cell[0] > 0 { cell[0] = cell[0] - 1 }
        AddTo(amount) => cell[0] = cell[0] + amount
      }
    },
    verify=fn(state) raise {
      if cell[0] != state {
        raise CounterMismatch("model says \{state}, counter holds \{cell[0]}")
      }
    },
  )
}

///|
pub suberror CounterMismatch {
  CounterMismatch(String)
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
test "the broken counter is caught and shrunk to a single command" {
  let cell = [0]
  let outcome = check_machine(
    make_broken_counter(cell),
    config=@prop.Config::new(count=200, max_size=12, seed=2024UL),
  )
  match outcome {
    @prop.Falsified(counterexample~, ..) => {
      // From zero, one decrement is already enough to disagree. Sequence
      // shrinking must discard every other command the run happened to draw.
      assert_eq(counterexample.length(), 1)
      assert_true(counterexample[0] is Decrement)
    }
    _ => abort("expected the broken counter to be caught")
  }
}

///|
test "the machine is reset between attempts, so shrinking is meaningful" {
  // If `reset` were skipped the counter would keep its value across attempts
  // and the very first command would appear to fail. Running the honest
  // machine many times proves the reset actually happens.
  let cell = [0]
  let machine = make_counter(cell)
  let outcome = check_machine(
    machine,
    config=@prop.Config::new(count=50, max_size=4, seed=11UL),
  )
  assert_true(outcome is @prop.Passed(_))
  // After the run the cell is whatever the last sequence left behind, but a
  // fresh run must still pass.
  let again = check_machine(
    machine,
    config=@prop.Config::new(count=50, max_size=4, seed=12UL),
  )
  assert_true(again is @prop.Passed(_))
}

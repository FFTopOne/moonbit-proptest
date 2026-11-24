///|
/// The result of walking a shrink tree.
pub struct ShrinkOutcome[T] {
  /// The simplest value found that still fails the property.
  value : T
  /// Child indices followed from the root, one per accepted step. Feeding this
  /// back into `Tree::follow` reconstructs exactly this value.
  path : Array[Int32]
  /// Accepted simplifications.
  steps : Int32
  /// Candidates examined, including the ones that were rejected because the
  /// property started passing again.
  attempts : Int32
  /// True when the step or attempt budget ran out while simpler candidates
  /// still existed, which means a smaller counterexample may be reachable with
  /// a larger budget.
  truncated : Bool
}

///|
/// Reduces a failing shrink tree to a locally minimal value.
///
/// The search is greedy and depth-first: at each node the children are tried in
/// order, the first one that still fails is adopted, and the rest are abandoned
/// along with their subtrees. Two consequences are worth stating because they
/// are what make the output trustworthy.
///
/// First, every value returned is reachable from the root by a path the
/// generator itself offered, so a counterexample can never be something the
/// generator would have refused to produce.
///
/// Second, the result is *locally* minimal rather than globally minimal:
/// no single child of it still fails, but a sibling the search declined to
/// explore might have been smaller. Global minimality is not decidable in
/// reasonable time on an infinite tree, and every practical property-testing
/// library accepts the same trade-off.
pub fn[T] shrink(
  tree : @tree.Tree[T],
  still_fails : (T) -> Bool,
  max_steps~ : Int32 = 100,
  max_attempts~ : Int32 = 1000,
) -> ShrinkOutcome[T] {
  let path : Array[Int32] = []
  let mut current = tree
  let mut steps = 0
  let mut attempts = 0
  let mut advanced = true
  while advanced && steps < max_steps && attempts < max_attempts {
    advanced = false
    let children = current.children()
    let mut index = 0
    while index < children.length() && !advanced {
      if steps < max_steps && attempts < max_attempts {
        attempts = attempts + 1
        if still_fails(children[index].value) {
          path.push(index)
          current = children[index]
          steps = steps + 1
          advanced = true
        }
      }
      index = index + 1
    }
  }
  {
    value: current.value,
    path,
    steps,
    attempts,
    truncated: (steps >= max_steps || attempts >= max_attempts) &&
    !current.is_leaf(),
  }
}

///|
test "shrinking drives an integer property to its exact boundary" {
  // The property fails for x >= 5. Whatever the draw, the reported value must
  // be 5 itself, not merely some value that happens to fail.
  let gen_tree = @tree.Tree::unfold(87, x => {
    if x <= 0 {
      []
    } else {
      [x / 2, x - 1].filter(c => c < x)
    }
  })
  let outcome = shrink(gen_tree, x => x >= 5)
  assert_eq(outcome.value, 5)
  assert_true(outcome.steps > 0)
}

///|
test "the recorded path reconstructs the reported value" {
  let gen_tree = @tree.Tree::unfold(200, x => {
    if x <= 0 {
      []
    } else {
      [x / 2, x - 1].filter(c => c < x)
    }
  })
  let outcome = shrink(gen_tree, x => x >= 17)
  assert_eq(outcome.value, 17)
  assert_eq(gen_tree.follow(outcome.path).unwrap().value, 17)
}

///|
test "a property that never fails is left at the root" {
  let gen_tree = @tree.Tree::unfold(50, x => if x <= 0 { [] } else { [x - 1] })
  let outcome = shrink(gen_tree, _ => false)
  assert_eq(outcome.value, 50)
  assert_eq(outcome.steps, 0)
  // The single candidate was examined and rejected, so it counts as an attempt.
  assert_eq(outcome.attempts, 1)
  assert_true(!outcome.truncated)
}

///|
test "the step budget truncates instead of looping forever" {
  // A descending chain with a property that fails at every value: without a
  // budget the search would walk to zero and beyond.
  let chain = @tree.Tree::unfold(100000, x => if x <= 0 { [] } else { [x - 1] })
  let outcome = shrink(chain, _ => true, max_steps=10)
  assert_eq(outcome.steps, 10)
  assert_true(outcome.truncated)
}

///|
test "a rejected candidate costs an attempt but not a step" {
  // Only even values are accepted by the property, so half the candidates are
  // examined and discarded.
  let gen_tree = @tree.Tree::unfold(64, x => {
    if x <= 0 {
      []
    } else {
      [x / 2, x - 1].filter(c => c < x)
    }
  })
  let outcome = shrink(gen_tree, x => x % 2 == 0 && x >= 8)
  assert_eq(outcome.value, 8)
  assert_true(outcome.attempts > outcome.steps)
}

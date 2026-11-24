///|
/// A rose tree: a value together with the trees of every way it can be
/// shrunk. Generators produce these instead of bare values.
///
/// The children are hidden behind a thunk on purpose. A shrink tree can be
/// enormous — every level multiplies the branching factor — while a search
/// for a minimal counterexample only ever walks one path down it. Forcing
/// children eagerly would turn a two-second property test into a hang, so
/// nothing below the root exists until somebody asks for it.
pub struct Tree[T] {
  value : T
  kids : () -> Array[Tree[T]]
}

///|
/// A tree with nothing to shrink to.
pub fn[T] Tree::singleton(value : T) -> Tree[T] {
  { value, kids: fn() { ([] : Array[Tree[T]]) }, }
}

///|
/// A tree whose children are already known.
pub fn[T] Tree::node(value : T, children : Array[Tree[T]]) -> Tree[T] {
  { value, kids: fn() { children }, }
}

///|
/// A tree whose children are computed on demand. This is the constructor
/// that every combinator should reach for.
pub fn[T] Tree::lazy_node(
  value : T,
  children : () -> Array[Tree[T]],
) -> Tree[T] {
  { value, kids: children, }
}

///|
/// Forces and returns the immediate children.
pub fn[T] Tree::children(self : Tree[T]) -> Array[Tree[T]] {
  (self.kids)()
}

///|
/// True when this node has no shrinks available.
pub fn[T] Tree::is_leaf(self : Tree[T]) -> Bool {
  self.children().is_empty()
}

///|
/// Maps a function over every value in the tree, preserving its shape.
///
/// The mapping stays inside thunks, so `map` never forces a subtree that the
/// search would not have visited anyway.
pub fn[T, U] Tree::map(self : Tree[T], f : (T) -> U) -> Tree[U] {
  Tree::lazy_node(f(self.value), fn() { self.children().map(c => c.map(f)) })
}

///|
/// Combines two trees applicatively: the result shrinks either side while
/// holding the other fixed.
///
/// Left-side shrinks are offered before right-side ones so that a minimal
/// counterexample is reached by simplifying the earlier-drawn value first,
/// which matches the order a reader of the test would expect.
pub fn[A, B, C] Tree::zip_with(
  self : Tree[A],
  other : Tree[B],
  f : (A, B) -> C,
) -> Tree[C] {
  Tree::lazy_node(f(self.value, other.value), fn() {
    let out : Array[Tree[C]] = []
    for child in self.children() {
      out.push(child.zip_with(other, f))
    }
    for child in other.children() {
      out.push(self.zip_with(child, f))
    }
    out
  })
}

///|
/// Drops every child — and by extension every descendant — whose value fails
/// `keep`.
///
/// This is how a generator keeps an invariant while still shrinking. Because
/// a rejected child is dropped together with its whole subtree, the surviving
/// tree only ever contains values that satisfied the predicate at generation
/// time, so shrinking can never produce a counterexample the generator itself
/// would have refused to emit.
///
/// The trade-off is real: if no immediate child satisfies `keep`, the node
/// becomes a leaf and shrinking stops there. Prefer encoding invariants
/// structurally (through `map` and `flat_map`) and keep `filter` for loose
/// constraints.
pub fn[T] Tree::filter(self : Tree[T], keep : (T) -> Bool) -> Tree[T] {
  Tree::lazy_node(self.value, fn() {
    let out : Array[Tree[T]] = []
    for child in self.children() {
      if keep(child.value) {
        out.push(child.filter(keep))
      }
    }
    out
  })
}

///|
/// Builds a tree from a shrink function, lazily and recursively.
///
/// `shrink` must be well founded: it may only return values that are strictly
/// closer to the intended minimum than its argument, or the tree will never
/// bottom out.
pub fn[T] Tree::unfold(value : T, shrink : (T) -> Array[T]) -> Tree[T] {
  Tree::lazy_node(value, fn() {
    shrink(value).map(v => Tree::unfold(v, shrink))
  })
}

///|
/// Walks `path` down the tree, returning the node it addresses.
///
/// This is the primitive behind replaying a recorded failure: a run stores the
/// generator seed plus the list of child indices it followed while shrinking,
/// and this function turns that pair back into the exact minimal value.
pub fn[T] Tree::follow(self : Tree[T], path : Array[Int32]) -> Tree[T]? {
  let mut current = self
  for index in path {
    let children = current.children()
    if index < 0 || index >= children.length() {
      return None
    }
    current = children[index]
  }
  Some(current)
}

///|
/// Counts nodes, stopping once `bound` have been seen.
///
/// A shrink tree is usually infinite in principle, so every measurement of one
/// needs a ceiling. Reporting the *bounded* size is enough to show how much
/// work a generator creates without forcing the whole structure.
pub fn[T] Tree::size_upto(self : Tree[T], bound : Int32) -> Int32 {
  let mut total = 0
  let mut pending : Array[Tree[T]] = [self]
  while !pending.is_empty() && total < bound {
    let next : Array[Tree[T]] = []
    for node in pending {
      if total < bound {
        total = total + 1
        for child in node.children() {
          next.push(child)
        }
      }
    }
    pending = next
  }
  total
}

///|
/// Renders the top of the tree as `value[a, b]`, cut off at `depth`.
///
/// Purely a human-facing aid: it makes shrink trees legible in test output and
/// in the README, where the shape of the search is the whole argument.
pub fn[T] Tree::shape(
  self : Tree[T],
  show : (T) -> String,
  depth~ : Int32 = 2,
) -> String {
  if depth <= 0 {
    return show(self.value)
  }
  let children = self.children()
  if children.is_empty() {
    return show(self.value)
  }
  let parts : Array[String] = []
  for child in children {
    parts.push(child.shape(show, depth=depth - 1))
  }
  let mut text = ""
  for i in 0..<parts.length() {
    if i > 0 {
      text = text + ", "
    }
    text = text + parts[i]
  }
  "\{show(self.value)}[\{text}]"
}

///|
test "a singleton has no shrinks" {
  let tree : Tree[Int32] = Tree::singleton(3)
  assert_eq(tree.children().length(), 0)
  assert_true(tree.is_leaf())
}

///|
test "children are not built until they are asked for" {
  // The counter is the point of the test: a generator that eagerly expands
  // its tree would blow up before the property ever runs.
  let built = [0]
  let tree : Tree[Int32] = Tree::lazy_node(10, fn() {
    built[0] = built[0] + 1
    [Tree::singleton(5), Tree::singleton(1)]
  })
  assert_eq(built[0], 0)
  let children = tree.children()
  assert_eq(built[0], 1)
  assert_eq(children.length(), 2)
  // Visiting a grandchild does not re-run the parent's thunk.
  assert_eq(children[0].children().length(), 0)
  assert_eq(built[0], 1)
}

///|
test "map preserves shape and stays lazy" {
  let tree : Tree[Int32] = Tree::lazy_node(2, fn() {
    [Tree::singleton(1), Tree::singleton(0)]
  })
  let doubled = tree.map(x => x * 2)
  assert_eq(doubled.value, 4)
  assert_eq(doubled.children().map(c => c.value), [2, 0])
}

///|
test "zip_with shrinks either side while the other holds" {
  let left : Tree[Int32] = Tree::node(4, [Tree::singleton(2)])
  let right : Tree[Int32] = Tree::node(5, [Tree::singleton(1)])
  let sum = left.zip_with(right, (a, b) => a + b)
  assert_eq(sum.value, 9)
  // First shrink the left operand (2 + 5), then the right (4 + 1).
  assert_eq(sum.children().map(c => c.value), [7, 5])
}

///|
test "filter prunes a whole subtree, not just its root" {
  // Halving and decrementing from 10: 10 -> {5, 9} -> {2,4} / {4,8}.
  let tree = Tree::unfold(10, x => if x <= 0 { [] } else { [x / 2, x - 1] })
  let big = tree.filter(x => x >= 4)
  assert_eq(big.value, 10)
  assert_eq(big.children().map(c => c.value), [5, 9])
  // 5 may only shrink to 4; its other candidate (2) is pruned together with
  // everything below it.
  assert_eq(big.children()[0].children().map(c => c.value), [4])
  assert_eq(big.children()[1].children().map(c => c.value), [4, 8])
}

///|
test "filter yields a leaf when every child violates the invariant" {
  // Documented limitation, pinned by a test so it cannot regress silently:
  // 10 may only shrink through even values, but both of its immediate
  // children are odd, so nothing survives.
  let tree = Tree::unfold(10, x => if x <= 0 { [] } else { [x / 2, x - 1] })
  let evens = tree.filter(x => x % 2 == 0)
  assert_eq(evens.value, 10)
  assert_eq(evens.children().length(), 0)
}

///|
test "unfold builds a well-founded shrink tree" {
  let tree = Tree::unfold(8, x => if x <= 0 { [] } else { [x / 2, x - 1] })
  assert_eq(tree.value, 8)
  assert_eq(tree.shape(x => x.to_string(), depth=1), "8[4, 7]")
  let followed = tree.follow([0, 0, 0])
  assert_eq(followed.unwrap().value, 1)
}

///|
test "follow reports an out-of-range path instead of panicking" {
  let tree = Tree::unfold(3, x => if x <= 0 { [] } else { [x - 1] })
  assert_true(tree.follow([0, 0, 0]) is Some(_))
  assert_true(tree.follow([0, 0, 0, 0]) is None)
  assert_true(tree.follow([-1]) is None)
}

///|
test "size_upto stops at its bound" {
  let deep = Tree::unfold(1000, x => if x <= 0 { [] } else { [x - 1] })
  assert_eq(deep.size_upto(10), 10)
}

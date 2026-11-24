///|
/// Edge cases of the tree rendering and walking helpers.

///|
test "a leaf renders as its own value, with no brackets" {
  // The empty-children branch: without it `shape` would print `7[]`, which is
  // noise in every report that shows a shrink tree.
  let leaf : Tree[Int32] = Tree::singleton(7)
  assert_eq(leaf.shape(x => x.to_string(), depth=3), "7")
}

///|
test "depth zero stops before looking at children" {
  let tree = Tree::unfold(9, x => if x <= 0 { [] } else { [x - 1] })
  assert_eq(tree.shape(x => x.to_string(), depth=0), "9")
}

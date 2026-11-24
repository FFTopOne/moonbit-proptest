///|
/// Edge cases of the state machine layer.

///|
test "commands render as their source names" {
  // The renderer backs every report the package produces, and it is easy to
  // leave one constructor unhandled without noticing.
  assert_eq(
    show_commands([Increment, Decrement, AddTo(2)]),
    "[Increment, Decrement, AddTo(2)]",
  )
  assert_eq(show_commands([]), "[]")
}

///|
test "the demo report names its defect and carries replay coordinates" {
  let text = demo_report()
  assert_true(text.contains("Capped counter"))
  assert_true(text.contains("replay"))
  assert_true(text.contains("seed="))
}

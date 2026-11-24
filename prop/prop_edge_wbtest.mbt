///|
/// Edge cases of the runner: the paths a passing suite never touches.

///|
test "check without an explicit config uses the documented defaults" {
  // The default is a fixed seed on purpose. If the `config` argument being
  // absent silently meant "random seed", CI would go flaky the moment this
  // branch was taken for the first time.
  let outcome = check(@gen.int_range(0, 10), x => x >= 0)
  assert_true(outcome is Passed(_))
  let again = check_raise(@gen.int_range(0, 10), fn(_) { () })
  assert_true(again is Passed(_))
}

///|
test "exceeding the discard limit gives up" {
  // Distinct from the "no case was judged at all" path: here the run gives up
  // because the budget specifically for refusals is spent.
  let refusing : @gen.Gen[Int32] = @gen.Gen::reject()
  let outcome = check(
    refusing,
    _ => true,
    config=Config::new(count=50, discard_limit=2),
  )
  match outcome {
    GaveUp(discarded~, ..) => assert_true(discarded > 2)
    _ => abort("expected GaveUp")
  }
}

///|
test "a passing outcome has nothing to replay" {
  let outcome = check(
    @gen.int_range(0, 10),
    x => x >= 0,
    config=Config::new(count=5),
  )
  assert_true(outcome.to_replay() is None)
}

///|
test "replay refuses a seed whose draw is discarded" {
  let refusing : @gen.Gen[Int32] = @gen.Gen::reject()
  let record : Replay = { case_seed: 1UL, size: 1, path: [], }
  assert_true(replay(refusing, record) is None)
}

///|
test "describe covers the passing and giving-up shapes" {
  let passed = check(
    @gen.int_range(0, 10),
    x => x >= 0,
    config=Config::new(count=5),
  )
  assert_true(passed.describe_with_debug().contains("PASSED"))
  let refusing : @gen.Gen[Int32] = @gen.Gen::reject()
  let gave_up = check(
    refusing,
    _ => true,
    config=Config::new(count=5, discard_limit=1),
  )
  assert_true(gave_up.describe_with_debug().contains("GAVE UP"))
}

///|
test "describe flags a truncated search instead of claiming minimality" {
  // With no shrink steps allowed, the result is still a counterexample but the
  // report must not call it minimal — a smaller one may well exist.
  let outcome = check(
    @gen.int_range(0, 100),
    x => x < 5,
    config=Config::new(count=50, max_steps=0, seed=77UL),
  )
  let text = outcome.describe_with_debug()
  assert_true(text.contains("budget exhausted"))
}

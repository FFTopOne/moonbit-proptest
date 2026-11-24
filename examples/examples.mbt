///|
/// Defect demonstrations.
///
/// Each example is a *mutant*: a correct algorithm with one deliberate edit
/// that a reader could plausibly have made, plus the property that catches it
/// and the exact minimal counterexample the shrinker must produce. Pinning the
/// minimal value is the point. A testing tool that finds a 40-element failing
/// array has proved nothing about its usefulness; a tool that reports `[1, 0]`
/// has handed the reader the bug.
///
/// These run as ordinary tests, so a regression in the shrinker shows up as a
/// failure here rather than as a worse report in the field.

///|
fn is_sorted(xs : Array[Int32]) -> Bool {
  let mut ordered = true
  let mut index = 1
  while index < xs.length() && ordered {
    if xs[index - 1] > xs[index] {
      ordered = false
    }
    index = index + 1
  }
  ordered
}

///|
/// Insertion sort with one changed bound.
///
/// The inner loop should walk all the way to index 0. Stopping at index 1
/// leaves the first slot frozen, so a small value that starts later can never
/// reach the front. Everything else about the algorithm is intact, which is
/// exactly why the defect survives casual reading.
fn insertion_sort_mutant(xs : Array[Int32]) -> Array[Int32] {
  let out = xs.copy()
  let mut i = 1
  while i < out.length() {
    let key = out[i]
    let mut j = i - 1
    while j >= 1 && out[j] > key {
      out[j + 1] = out[j]
      j = j - 1
    }
    out[j + 1] = key
    i = i + 1
  }
  out
}

///|
/// A correct insertion sort, used as the reference the shrinker is compared
/// against in the second assertion of the demo.
fn insertion_sort(xs : Array[Int32]) -> Array[Int32] {
  let out = xs.copy()
  let mut i = 1
  while i < out.length() {
    let key = out[i]
    let mut j = i - 1
    while j >= 0 && out[j] > key {
      out[j + 1] = out[j]
      j = j - 1
    }
    out[j + 1] = key
    i = i + 1
  }
  out
}

///|
/// Run-length encodes `xs` into `(value, count)` pairs.
///
/// The mutation is the `count > 1` guard: runs of length one are silently
/// dropped, so any value that appears exactly once disappears on the round
/// trip.
fn rle_encode_mutant(xs : Array[Int32]) -> Array[(Int32, Int32)] {
  let out : Array[(Int32, Int32)] = []
  let mut index = 0
  while index < xs.length() {
    let value = xs[index]
    let mut count = 1
    while index + count < xs.length() && xs[index + count] == value {
      count = count + 1
    }
    if count > 1 {
      out.push((value, count))
    }
    index = index + count
  }
  out
}

///|
fn rle_decode(pairs : Array[(Int32, Int32)]) -> Array[Int32] {
  let out : Array[Int32] = []
  for pair in pairs {
    let (value, count) = pair
    for _ in 0..<count {
      out.push(value)
    }
  }
  out
}

///|
/// Reverses a string, but loses the middle character when the length is odd.
fn reverse_mutant(text : String) -> String {
  let chars = text.to_array()
  let out : Array[Char] = []
  let length = chars.length()
  for i in 0..<length {
    // The mutation: the middle character of an odd-length string is skipped.
    let is_middle = length % 2 == 1 && i == length / 2
    if !is_middle {
      out.push(chars[length - 1 - i])
    }
  }
  let mut result = ""
  for char in out {
    result = result + char.to_string()
  }
  result
}

///|
pub fn is_sorted_public(xs : Array[Int32]) -> Bool {
  is_sorted(xs)
}

///|
/// Formats one finding for a report.
fn section(title : String, body : String) -> String {
  "\n### \{title}\n\{body}"
}

///|
/// Runs every defect demo and returns a human-readable report.
///
/// The same function backs both the CLI and the README, so the printed output
/// is never a transcription of what the tool once did.
pub fn run_all() -> String {
  let mut report = "MoonBit property testing — defect demos\n"

  let sort_outcome = @prop.check(
    @gen.int_range(0, 100).array_of(),
    xs => is_sorted(insertion_sort_mutant(xs)),
    config=@prop.Config::new(count=300, max_size=8, seed=1UL),
  )
  let sort_part = section(
    "Insertion sort frozen at index 0",
    sort_outcome.describe_with_debug(),
  )
  report = report + sort_part

  let rle_outcome = @prop.check(
    @gen.int_range(0, 5).array_of(),
    xs => rle_decode(rle_encode_mutant(xs)) == xs,
    config=@prop.Config::new(count=300, max_size=8, seed=2UL),
  )
  let rle_part = section(
    "Run-length encoding drops single runs",
    rle_outcome.describe_with_debug(),
  )
  report = report + rle_part

  let reverse_outcome = @prop.check(
    @gen.string(),
    text => reverse_mutant(reverse_mutant(text)) == text,
    config=@prop.Config::new(count=300, max_size=6, seed=3UL),
  )
  let reverse_part = section(
    "String reverse loses the middle character",
    reverse_outcome.describe_with_debug(),
  )
  report = report + reverse_part

  report
}

///|
test "the sort mutant is caught and shrunk to a two-element array" {
  // Any two-element descending pair is enough, and no single element ever is,
  // so `[1, 0]` is the smallest witness the shrinker can reach.
  let outcome = @prop.check(
    @gen.int_range(0, 100).array_of(),
    xs => is_sorted(insertion_sort_mutant(xs)),
    config=@prop.Config::new(count=300, max_size=8, seed=1UL),
  )
  match outcome {
    @prop.Falsified(counterexample~, ..) => assert_eq(counterexample, [1, 0])
    _ => abort("expected the mutant to be caught")
  }
}

///|
test "the reference sort passes the same property" {
  // The property itself must not be the thing that is broken: swapping in a
  // correct implementation has to make the failure disappear. This is the
  // control that keeps the demo honest.
  let outcome = @prop.check(
    @gen.int_range(0, 100).array_of(),
    xs => is_sorted(insertion_sort(xs)),
    config=@prop.Config::new(count=300, max_size=8, seed=1UL),
  )
  assert_true(outcome is @prop.Passed(_))
}

///|
test "the run-length mutant is caught and shrunk to a single element" {
  let outcome = @prop.check(
    @gen.int_range(0, 5).array_of(),
    xs => rle_decode(rle_encode_mutant(xs)) == xs,
    config=@prop.Config::new(count=300, max_size=8, seed=2UL),
  )
  match outcome {
    @prop.Falsified(counterexample~, ..) => assert_eq(counterexample, [0])
    _ => abort("expected the mutant to be caught")
  }
}

///|
test "the string mutant is caught" {
  let outcome = @prop.check(
    @gen.string(),
    text => reverse_mutant(reverse_mutant(text)) == text,
    config=@prop.Config::new(count=300, max_size=6, seed=3UL),
  )
  match outcome {
    @prop.Falsified(counterexample~, ..) =>
      // A single character is enough: it is the middle of itself.
      assert_eq(counterexample.length(), 1)
    _ => abort("expected the mutant to be caught")
  }
}

///|
test "the report mentions every demo and its replay coordinates" {
  let report = run_all()
  assert_true(report.contains("Insertion sort"))
  assert_true(report.contains("Run-length"))
  assert_true(report.contains("String reverse"))
  assert_true(report.contains("seed="))
}

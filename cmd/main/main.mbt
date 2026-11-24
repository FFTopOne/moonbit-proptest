///|
/// Reprogrammable entry point for the defect demos.
///
/// Run with `moon run cmd/main` from the module root. The output is produced by
/// the same `run_all` the tests use, so it cannot drift from what the library
/// actually reports.
fn main {
  println(@examples.run_all())
  println("\nEvery report above is reproducible from the seed, size and shrink")
  println("path it prints, via @prop.replay — no stored fixture involved.")
}

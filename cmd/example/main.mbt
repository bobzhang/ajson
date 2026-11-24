///|
/// Example: streaming JSON from standard input.
///
/// - `count`: counts the elements of a top-level array without
///   building them.
/// - `field NAME`: reads newline-delimited JSON and prints field `NAME`
///   of each value, or `null`.
async fn run() -> Unit {
  match @env.args()[1:] {
    ["count"] => {
      let parser = @ajson.Parser::from_reader(@stdio.stdin.text)
      guard parser.next_event() is Some(StartArray) else {
        fail("expected a top-level array")
      }
      let mut count = 0
      while parser.skip_value() {
        count += 1
      }
      // Rejects trailing input after the array.
      guard parser.next_event() is None else { fail("unreachable") }
      println(count)
    }
    ["field", name] => {
      let parser = @ajson.Parser::from_reader(
        @stdio.stdin.text,
        multiple_values=true,
      )
      parser.each_value(value => {
        if value is Object(members) && members.get(name) is Some(field) {
          println(field.stringify())
        } else {
          println("null")
        }
      })
    }
    _ => fail("usage: example count | example field NAME")
  }
}

///|
fn main {
  @async.run_async_main(run)
}

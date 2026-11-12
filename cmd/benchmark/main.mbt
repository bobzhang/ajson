///|
/// A document of `n` records, about 120 bytes each.
fn make_document(n : Int32) -> String {
  let sb = StringBuilder()
  sb.write_string("[\n")
  for i in 0..<n {
    if i > 0 {
      sb.write_string(",\n")
    }
    sb.write_string(
      "  {\"id\": \{i}, \"name\": \"user \{i} caf\\u00e9\", \"score\": \{i.to_double() * 1.25}, \"tags\": [\"a\", \"bc\"], \"active\": \{i % 2 == 0}, \"extra\": null}",
    )
  }
  sb.write_string("\n]\n")
  sb.to_string()
}

///|
/// A source returning `doc` in chunks of `size` code units.
fn chunked(doc : String, size : Int32) -> @lexbuf.AsyncLexbuf {
  let mut pos = 0
  @lexbuf.AsyncLexbuf::from_fn(() => {
    if pos >= doc.length() {
      return None
    }
    let end = if pos + size < doc.length() { pos + size } else { doc.length() }
    let chunk = doc.exact_view(start=pos, end~).to_owned()
    pos = end
    Some(chunk)
  })
}

///|
/// Runs `f` `runs` times and returns the median time in milliseconds.
async fn median_ms(runs : Int32, f : async () -> Unit) -> Double {
  let times = []
  for _ in 0..<runs {
    let start = @bench.monotonic_clock_start()
    f()
    times.push(@bench.monotonic_clock_end(start) / 1000.0)
  }
  times.sort()
  times[runs / 2]
}

///|
/// Compares `@json.parse` on a whole in-memory string with this parser
/// reading the same text in 64 KiB chunks.
async fn main {
  let doc = make_document(20000)
  let expected = @json.parse(doc)
  let mb = doc.length().to_double() / 1048576.0
  let runs = 11
  let mut sink = 0
  fn report(name : String, ms : Double) {
    println("\{name}: \{ms} ms, \{mb / (ms / 1000.0)} MB/s")
  }

  println("document: \{doc.length()} code units")
  report(
    "@json.parse (whole string)",
    median_ms(runs, () => {
      guard (@json.parse(doc) catch { _ => panic() }) is Array(a) else {
        panic()
      }
      sink += a.length()
    }),
  )
  report(
    "ajson next_value",
    median_ms(runs, () => {
      let p = @ajson.Parser::new(chunked(doc, 65536))
      guard p.next_value() is Some(v) && v == expected else { panic() }
    }),
  )
  report(
    "ajson events only",
    median_ms(runs, () => {
      let p = @ajson.Parser::new(chunked(doc, 65536))
      while p.next_event() is Some(_) {
        sink += 1
      }
    }),
  )
  report(
    "ajson next_value, max_string_length set",
    median_ms(runs, () => {
      let p = @ajson.Parser::new(chunked(doc, 65536), max_string_length=1 << 20)
      guard p.next_value() is Some(v) && v == expected else { panic() }
    }),
  )
  ignore(sink)
}

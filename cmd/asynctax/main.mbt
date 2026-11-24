///|
/// Measures the cost of `lexscan` over `AsyncLexbuf` against the synchronous
/// targets: the same capture-heavy object-member regex, as in ajson's fast
/// scanner, over `StringScanner`, `Lexbuf` and `AsyncLexbuf`, with the
/// streaming targets fed 64 KiB chunks.
fn scan_sync(lb : @lexbuf.Lexbuf) -> Int32 {
  lexscan lb with longest {
    (re"^[ \t\r\n]*,[ \t\r\n]*\"" as h1) +
    (re"(?:[^\"\\\u{0}-\u{1f}]|\\[\"\\/bfnrt]|\\u[0-9a-fA-F]{4})*" as k) +
    (re"\"[ \t\r\n]*:[ \t\r\n]*" as h2) +
    (
      re"\"(?:[^\"\\\u{0}-\u{1f}]|\\[\"\\/bfnrt]|\\u[0-9a-fA-F]{4})*\"|-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+\-]?[0-9]+)?|true|false|null" as v
    ) => h1.length() + k.length() + h2.length() + v.length()
    _ => -1
  }
}

///|
async fn scan_async(lb : @lexbuf.AsyncLexbuf) -> Int32 {
  lexscan lb with longest {
    (re"^[ \t\r\n]*,[ \t\r\n]*\"" as h1) +
    (re"(?:[^\"\\\u{0}-\u{1f}]|\\[\"\\/bfnrt]|\\u[0-9a-fA-F]{4})*" as k) +
    (re"\"[ \t\r\n]*:[ \t\r\n]*" as h2) +
    (
      re"\"(?:[^\"\\\u{0}-\u{1f}]|\\[\"\\/bfnrt]|\\u[0-9a-fA-F]{4})*\"|-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+\-]?[0-9]+)?|true|false|null" as v
    ) => h1.length() + k.length() + h2.length() + v.length()
    _ => -1
  }
}

///|
fn scan_scanner(lb : @lexbuf.StringScanner) -> Int32 {
  lexscan lb with longest {
    (re"^[ \t\r\n]*,[ \t\r\n]*\"" as h1) +
    (re"(?:[^\"\\\u{0}-\u{1f}]|\\[\"\\/bfnrt]|\\u[0-9a-fA-F]{4})*" as k) +
    (re"\"[ \t\r\n]*:[ \t\r\n]*" as h2) +
    (
      re"\"(?:[^\"\\\u{0}-\u{1f}]|\\[\"\\/bfnrt]|\\u[0-9a-fA-F]{4})*\"|-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+\-]?[0-9]+)?|true|false|null" as v
    ) => h1.length() + k.length() + h2.length() + v.length()
    _ => -1
  }
}

///|
fn chunks(doc : String) -> () -> String? {
  let mut pos = 0
  () => {
    if pos >= doc.length() {
      return None
    }
    let end = if pos + 65536 < doc.length() {
      pos + 65536
    } else {
      doc.length()
    }
    let c = doc.exact_view(start=pos, end~).to_owned()
    pos = end
    Some(c)
  }
}

///|
async fn run() -> Unit {
  let sb = StringBuilder()
  for i in 0..<200000 {
    sb.write_string(", \"key\{i % 10}\": \{i}")
  }
  let doc = sb.to_string()
  let runs = 9
  fn med(ts : Array[Double]) -> Double {
    ts.sort()
    ts[ts.length() / 2]
  }

  let t1 = []
  let t2 = []
  let t3 = []
  let mut total = 0
  for _ in 0..<runs {
    let s = @bench.monotonic_clock_start()
    let sc = @lexbuf.StringScanner(doc)
    while scan_scanner(sc) > 0 {
      total += 1
    }
    t1.push(@bench.monotonic_clock_end(s) / 1000.0)
    let s = @bench.monotonic_clock_start()
    let lb = @lexbuf.Lexbuf::from_fn(chunks(doc))
    while scan_sync(lb) > 0 {
      total += 1
    }
    t2.push(@bench.monotonic_clock_end(s) / 1000.0)
    let s = @bench.monotonic_clock_start()
    let next = chunks(doc)
    let alb = @lexbuf.AsyncLexbuf::from_fn(() => next())
    while scan_async(alb) > 0 {
      total += 1
    }
    t3.push(@bench.monotonic_clock_end(s) / 1000.0)
  }
  println("200000 member scans; total \{total}")
  println("StringScanner: \{med(t1)} ms")
  println("Lexbuf:        \{med(t2)} ms")
  println("AsyncLexbuf:   \{med(t3)} ms")
}

///|
fn main {
  @async.run_async_main(run)
}

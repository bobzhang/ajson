///|
/// A source returning `parts` one by one.
fn chunks(parts : Array[String]) -> async () -> String? {
  let mut i = 0
  () => {
    if i < parts.length() {
      i += 1
      Some(parts[i - 1])
    } else {
      None
    }
  }
}

///|
/// Equality that also compares key order, the sign of zero and `repr`.
fn strict_eq(a : Json, b : Json) -> Bool {
  match (a, b) {
    (Null, Null) | (True, True) | (False, False) => true
    (Number(x, repr=rx), Number(y, repr=ry)) =>
      x.reinterpret_as_int64() == y.reinterpret_as_int64() && rx == ry
    (String(x), String(y)) => x == y
    (Array(xs), Array(ys)) =>
      xs.length() == ys.length() &&
      xs.iter().zip(ys.iter()).all(p => strict_eq(p.0, p.1))
    (Object(xs), Object(ys)) =>
      xs.length() == ys.length() &&
      xs
      .iter()
      .zip(ys.iter())
      .all(p => p.0.0 == p.1.0 && strict_eq(p.0.1, p.1.1))
    _ => false
  }
}

///|
/// Parses exactly one document from `parts`, as `@json.parse` would.
async fn parse_parts(
  parts : Array[String],
  max_string_length? : Int32,
  max_depth~ : Int32 = 1024,
) -> Result[Json, Error] {
  let p = @ajson.Parser::new(
    @lexbuf.AsyncLexbuf::from_fn(chunks(parts)),
    max_string_length?,
    max_depth~,
  )
  try {
    guard p.next_value() is Some(v) else { fail("no value") }
    guard p.next_value() is None else { fail("more than one value") }
    Ok(v)
  } catch {
    e => Err(e)
  }
}

///|
/// Parses one document from UTF-8 `parts` through `MemoryReader` and
/// `Utf8Reader`.
async fn parse_bytes(parts : Array[Bytes]) -> Result[Json, Error] {
  let bytes = @io.MemoryReader(w => {
    for part in parts {
      w.write(part)
    }
  })
  // Stops the writer if the parser stops reading early.
  defer bytes.close()
  let p = @ajson.Parser::from_reader(@io.Utf8Reader(bytes))
  try {
    guard p.next_value() is Some(v) else { fail("no value") }
    guard p.next_value() is None else { fail("more than one value") }
    Ok(v)
  } catch {
    e => Err(e)
  }
}

///|
/// Checks that `got` agrees with `@json.parse(input)`: both accept with
/// strictly equal values, or both reject.
fn agree(
  input : String,
  got : Result[Json, Error],
  what : String,
) -> Unit raise {
  let expected = Ok(@json.parse(input)) catch { e => Err(e) }
  match (expected, got) {
    (Ok(x), Ok(y)) =>
      if !strict_eq(x, y) {
        fail(
          "\{what}: \{input.escape()}: got \{y.stringify()}, expected \{x.stringify()}",
        )
      }
    (Err(_), Err(_)) => ()
    (Ok(_), Err(e)) => fail("\{what}: \{input.escape()}: rejected: \{e}")
    (Err(e), Ok(y)) =>
      fail(
        "\{what}: \{input.escape()}: accepted as \{y.stringify()}, but @json.parse says \{e}",
      )
  }
}

///|
/// Checks `input` whole and in every two-way split, in both scanning modes,
/// split at character boundaries and at UTF-8 byte boundaries.
async fn check_all_splits(input : String) -> Unit {
  agree(input, parse_parts([input]), "whole")
  agree(input, parse_parts([input], max_string_length=1 << 30), "limited")
  let boundaries = [0]
  for c in input {
    boundaries.push(boundaries[boundaries.length() - 1] + c.utf16_len())
  }
  for i in boundaries {
    let left = input.exact_view(end=i).to_owned()
    let right = input.exact_view(start=i).to_owned()
    agree(input, parse_parts([left, right]), "split at \{i}")
    agree(
      input,
      parse_parts([left, right], max_string_length=1 << 30),
      "limited split at \{i}",
    )
  }
  let bytes = @utf8.encode(input)
  for i in 0..<=bytes.length() {
    agree(
      input,
      parse_bytes([bytes[:i].to_owned(), bytes[i:].to_owned()]),
      "byte split at \{i}",
    )
  }
}

///|
/// Collects all events of a single-document input, or the error.
async fn events(
  input : String,
  multiple_values~ : Bool = false,
  max_string_length? : Int32,
) -> Result[Array[@ajson.Event], Error] {
  let p = @ajson.Parser::new(
    @lexbuf.AsyncLexbuf::from_fn(chunks([input])),
    multiple_values~,
    max_string_length?,
  )
  let out = []
  try {
    while p.next_event() is Some(e) {
      out.push(e)
    }
    Ok(out)
  } catch {
    e => Err(e)
  }
}

///|
/// Whether two results are equal, comparing errors by their messages.
fn[T : Eq] same_result(a : Result[T, Error], b : Result[T, Error]) -> Bool {
  match (a, b) {
    (Ok(x), Ok(y)) => x == y
    (Err(x), Err(y)) => x.to_string() == y.to_string()
    _ => false
  }
}

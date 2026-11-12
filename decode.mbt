///|
/// The position of `offset`, which must be on the current line.
fn Parser::pos_at(self : Parser, offset : Int32) -> Position {
  { offset, line: self.line, column: offset - self.line_start, }
}

///|
/// Decodes the body of a string literal (without its quotes) that the fast
/// scanner has validated, so every escape is well formed. `base` is the
/// offset of the body, for errors.
fn Parser::decode_string(
  self : Parser,
  body : StringView,
  base : Int32,
) -> String raise ParseError {
  let len = body.length()
  let mut i = 0
  while i < len && body.unsafe_get(i) != '\\' {
    i += 1
  }
  if i == len {
    return body.to_owned()
  }
  let sb = StringBuilder(size_hint=len)
  let mut run = 0
  while i < len {
    if body.unsafe_get(i) != '\\' {
      i += 1
      continue
    }
    if i > run {
      sb.write_view(body[run:i])
    }
    match body.unsafe_get(i + 1) {
      'u' => {
        let c = hex4(body, i + 2)
        if c is (0xD800..<=0xDBFF) {
          guard i + 11 < len &&
            body.unsafe_get(i + 6) == '\\' &&
            body.unsafe_get(i + 7) == 'u' else {
            raise UnpairedSurrogate(self.pos_at(base + i))
          }
          let c2 = hex4(body, i + 8)
          guard c2 is (0xDC00..<=0xDFFF) else {
            raise UnpairedSurrogate(self.pos_at(base + i))
          }
          sb.write_char(((c << 10) + c2 - 0x35fdc00).unsafe_to_char())
          i += 12
        } else if c is (0xDC00..<=0xDFFF) {
          raise UnpairedSurrogate(self.pos_at(base + i))
        } else {
          sb.write_char(c.unsafe_to_char())
          i += 6
        }
      }
      e => {
        sb.write_char(unescape(e.to_int()))
        i += 2
      }
    }
    run = i
  }
  if run < len {
    sb.write_view(body[run:len])
  }
  sb.to_string()
}

///|
/// The character a single-character escape `\e` stands for.
fn unescape(e : Int32) -> Char {
  match e {
    'b' => '\b'
    'f' => '\u{0C}'
    'n' => '\n'
    'r' => '\r'
    't' => '\t'
    '"' => '"'
    '\\' => '\\'
    '/' => '/'
    _ => abort("unreachable: unvalidated escape")
  }
}

///|
/// The value of the four hex digits at `start`, which must be valid.
fn hex4(s : StringView, start : Int32) -> Int32 {
  let mut n = 0
  for i in start..<(start + 4) {
    let c = s.unsafe_get(i).to_int()
    let d = if c <= '9' { c - '0' } else { (c | 0x20) - 'a' + 10 }
    n = (n << 4) | d
  }
  n
}

///|
/// Converts a validated JSON number literal to the value `@json.parse` gives.
/// Short integers are converted here; anything else goes to `@json.parse`,
/// which keeps rounding and `repr` identical.
fn number_value(text : StringView) -> Json {
  let len = text.length()
  let negative = text.unsafe_get(0) == '-'
  let start = if negative { 1 } else { 0 }
  // At most 15 digits: below 2^53, so the double is exact.
  if len - start <= 15 {
    let mut acc = 0L
    let mut simple = true
    for i in start..<len {
      let c = text.unsafe_get(i).to_int()
      if c < '0' || c > '9' {
        simple = false
        break
      }
      acc = acc * 10L + (c - '0').to_int64()
    }
    if simple {
      let v = acc.to_double()
      return Json::number(if negative { -v } else { v })
    }
  }
  @json.parse(text) catch {
    _ => abort("unreachable: invalid number literal")
  }
}

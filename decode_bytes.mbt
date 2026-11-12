///|
/// Advances over UTF-8 `text`, which may contain line breaks.
fn Parser::advance_text_b(self : Parser, text : BytesView) -> Unit {
  let base = self.offset
  for i in 0..<text.length() {
    if text[i] == b'\n' {
      self.line += 1
      self.line_start = base + i + 1
    }
  }
  self.offset = base + text.length()
}

///|
/// Decodes UTF-8 that a scanner regex has validated.
fn decode_utf8(s : BytesView) -> String {
  @utf8.decode(s) catch {
    _ => abort("unreachable: unvalidated UTF-8")
  }
}

///|
/// The code point of one validated UTF-8 character.
fn decode_char(s : BytesView) -> Int32 {
  let b0 = s[0].to_int()
  match s.length() {
    1 => b0
    2 => ((b0 & 0x1F) << 6) | (s[1].to_int() & 0x3F)
    3 =>
      ((b0 & 0x0F) << 12) |
      ((s[1].to_int() & 0x3F) << 6) |
      (s[2].to_int() & 0x3F)
    _ =>
      ((b0 & 0x07) << 18) |
      ((s[1].to_int() & 0x3F) << 12) |
      ((s[2].to_int() & 0x3F) << 6) |
      (s[3].to_int() & 0x3F)
  }
}

///|
/// Appends ASCII bytes to `sb`.
fn write_ascii(sb : StringBuilder, s : BytesView) -> Unit {
  for b in s {
    sb.write_char(b.to_int().unsafe_to_char())
  }
}

///|
/// `decode_string` for the body of a validated UTF-8 string literal; `base`
/// is the byte offset of the body, for errors.
fn Parser::decode_bytes_string(
  self : Parser,
  body : BytesView,
  base : Int32,
) -> String raise ParseError {
  let len = body.length()
  let mut i = 0
  while i < len && body[i] != b'\\' {
    i += 1
  }
  if i == len {
    return decode_utf8(body)
  }
  let sb = StringBuilder(size_hint=len)
  let mut run = 0
  while i < len {
    if body[i] != b'\\' {
      i += 1
      continue
    }
    if i > run {
      sb.write_string(decode_utf8(body[run:i]))
    }
    match body[i + 1] {
      b'u' => {
        let c = hex4_b(body, i + 2)
        if c is (0xD800..<=0xDBFF) {
          guard i + 11 < len && body[i + 6] == b'\\' && body[i + 7] == b'u' else {
            raise UnpairedSurrogate(self.pos_at(base + i))
          }
          let c2 = hex4_b(body, i + 8)
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
    sb.write_string(decode_utf8(body[run:len]))
  }
  sb.to_string()
}

///|
/// `hex4` over bytes.
fn hex4_b(s : BytesView, start : Int32) -> Int32 {
  let mut n = 0
  for i in start..<(start + 4) {
    let c = s[i].to_int()
    let d = if c <= '9' { c - '0' } else { (c | 0x20) - 'a' + 10 }
    n = (n << 4) | d
  }
  n
}

///|
/// `number_value` for a validated number literal in ASCII bytes.
fn number_value_bytes(text : BytesView) -> Json {
  let len = text.length()
  let negative = text[0] == b'-'
  let start = if negative { 1 } else { 0 }
  if len - start <= 15 {
    let mut acc = 0L
    let mut simple = true
    for i in start..<len {
      let c = text[i].to_int()
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
  let sb = StringBuilder(size_hint=len)
  write_ascii(sb, text)
  number_value(sb.to_string())
}

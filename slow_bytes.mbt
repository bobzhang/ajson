// The slow scanner for UTF-8 bytes input: `slow.mbt` with `reb` regexes.
// Malformed UTF-8 is reported as `InvalidUtf8`.

///|
async fn Parser::slow_step_b(self : Parser) -> Unit {
  match self.state {
    Value => {
      let ws = self.slow_ws_b()
      self.slow_value_b(ws)
    }
    ArrayFirst => {
      self.slow_ws_b() |> ignore
      if self.slow_close_bracket_b() {
        self.close()
      } else {
        self.slow_value_b(1)
      }
    }
    ArrayNext => {
      self.slow_ws_b() |> ignore
      let pos = self.pos()
      match self.slow_punct_b() {
        ']' => self.close()
        ',' => {
          self.slow_ws_b() |> ignore
          self.slow_value_b(1)
        }
        c => self.unexpected_b(pos, c)
      }
    }
    ObjectFirst => {
      self.slow_ws_b() |> ignore
      let pos = self.pos()
      match self.slow_punct_b() {
        '}' => self.close()
        '"' => self.slow_member_b(pos)
        c => self.unexpected_b(pos, c)
      }
    }
    ObjectNext => {
      self.slow_ws_b() |> ignore
      let pos = self.pos()
      match self.slow_punct_b() {
        '}' => self.close()
        ',' => {
          self.slow_ws_b() |> ignore
          let pos = self.pos()
          match self.slow_punct_b() {
            '"' => self.slow_member_b(pos)
            c => self.unexpected_b(pos, c)
          }
        }
        c => self.unexpected_b(pos, c)
      }
    }
    TopEnd =>
      if self.multiple_values {
        self.state = Value
      } else {
        self.slow_ws_b() |> ignore
        if self.slow_eof_b() {
          self.state = Finished
        } else {
          self.fail_here_b()
        }
      }
    Finished => ()
  }
}

///|
/// Reports `c`, consumed by `slow_punct` at `pos`, as unexpected; or, if
/// `slow_punct` consumed nothing (`c` is -1), the next character.
async fn[T] Parser::unexpected_b(self : Parser, pos : Position, c : Int32) -> T {
  if c < 0 {
    self.fail_here_b()
  } else {
    raise UnexpectedChar(pos, c.unsafe_to_char())
  }
}

///|
/// Raises the error for the next character, or for the end of the input.
async fn[T] Parser::fail_here_b(self : Parser) -> T {
  let pos = self.pos()
  // A character, or -2 at the end of the input, or -1 if the next bytes are
  // not well-formed UTF-8.
  let c = lexscan self.binary() with longest {
    reb"^(?:[\x00-\x7f]|[\xc2-\xdf][\x80-\xbf]|\xe0[\xa0-\xbf][\x80-\xbf]|[\xe1-\xec\xee\xef][\x80-\xbf]{2}|\xed[\x80-\x9f][\x80-\xbf]|\xf0[\x90-\xbf][\x80-\xbf]{2}|[\xf1-\xf3][\x80-\xbf]{3}|\xf4[\x80-\x8f][\x80-\xbf]{2})" as c =>
      decode_char(c)
    reb"^$" => -2
    _ => -1
  }
  match c {
    -2 => raise UnexpectedEof(pos)
    -1 => raise InvalidUtf8(pos)
    c => raise UnexpectedChar(pos, c.unsafe_to_char())
  }
}

///|
/// Skips whitespace and returns the number of code units skipped.
async fn Parser::slow_ws_b(self : Parser) -> Int32 {
  let start = self.offset
  for ;; {
    let more = lexscan self.binary() with longest {
      reb"^[ \t\r]{1,64}" as w => {
        self.advance(w.length())
        true
      }
      reb"^\n" => {
        self.newline()
        true
      }
      _ => false
    }
    if !more {
      break
    }
  }
  self.offset - start
}

///|
async fn Parser::slow_eof_b(self : Parser) -> Bool {
  lexscan self.binary() with longest {
    reb"^$" => true
    _ => false
  }
}

///|
async fn Parser::slow_close_bracket_b(self : Parser) -> Bool {
  lexscan self.binary() with longest {
    reb"^\]" => {
      self.advance(1)
      true
    }
    _ => false
  }
}

///|
/// Consumes one of `,:]}"` and returns it, or returns -1 and consumes nothing.
async fn Parser::slow_punct_b(self : Parser) -> Int32 {
  let c = lexscan self.binary() with longest {
    reb"^," => ','.to_int()
    reb"^:" => ':'.to_int()
    reb"^\]" => ']'.to_int()
    reb"^[}]" => '}'.to_int()
    reb"^\"" => '"'.to_int()
    _ => -1
  }
  if c >= 0 {
    self.advance(1)
  }
  c
}

///|
/// Scans the rest of a member after its opening quote at `quote`: the
/// property name, whitespace and `:`.
async fn Parser::slow_member_b(self : Parser, quote : Position) -> Unit {
  let key = self.slow_string_b(quote)
  self.pending.push(Key(key))
  self.slow_ws_b() |> ignore
  let pos = self.pos()
  match self.slow_punct_b() {
    ':' => self.state = Value
    c => self.unexpected_b(pos, c)
  }
}

///|
/// Scans a value after `ws` code units of whitespace. At the top level of a
/// multi-value stream the end of the input is accepted instead.
async fn Parser::slow_value_b(self : Parser, ws : Int32) -> Unit {
  let pos = self.pos()
  // The length of a literal prefix, consumed only after the separator check.
  let mut partial = 0
  let mut first = 't'
  // A code for what starts here: the character for a container, a string or
  // a number; 't', 'f' or 'n' for a whole literal; 0 for the prefix of a
  // literal; -2 for the end of the input; -1 for anything else.
  let kind = lexscan self.binary() with longest {
    reb"^[{]" => '{'.to_int()
    reb"^\[" => '['.to_int()
    reb"^\"" => '"'.to_int()
    reb"^true" => 't'.to_int()
    reb"^false" => 'f'.to_int()
    reb"^null" => 'n'.to_int()
    reb"^-" => '-'.to_int()
    reb"^[0-9]" as d => d.to_int()
    reb"^(?:t(?:ru?)?|f(?:a(?:ls?)?)?|n(?:ul?)?)" as p => {
      partial = p.length()
      first = p[0].to_int().unsafe_to_char()
      0
    }
    reb"^$" => -2
    _ => -1
  }
  if kind == -2 && self.stack.is_empty() && self.multiple_values {
    self.state = Finished
    return
  }
  if self.multiple_values && kind != -2 {
    // A missing separator is reported before anything wrong in the value.
    // For -1 the next character is reported anyway.
    if kind >= 0 {
      self.check_separator(
        ws,
        if kind == 0 {
          first
        } else {
          kind.unsafe_to_char()
        },
      )
    }
  }
  if kind <= 0 {
    self.advance(partial)
    self.fail_here_b()
  }
  match kind {
    '{' | '[' => {
      self.open(kind == '{', pos)
      self.advance(1)
    }
    '"' => {
      self.advance(1)
      let s = self.slow_string_b(pos)
      self.scalar(Json::string(s), false)
    }
    't' => {
      self.advance(4)
      self.scalar(Json::boolean(true), true)
    }
    'f' => {
      self.advance(5)
      self.scalar(Json::boolean(false), true)
    }
    'n' => {
      self.advance(4)
      self.scalar(Json::null(), true)
    }
    _ => {
      self.advance(1)
      self.slow_number_b(pos, kind)
    }
  }
}

///|
/// Scans the rest of a string after its opening quote at `quote` and returns
/// its decoded contents.
async fn Parser::slow_string_b(self : Parser, quote : Position) -> String {
  let sb = StringBuilder()
  let mut len = 0
  for ;; {
    let pos = self.pos()
    // The number of code units added, or -1 at the closing quote, -2 for an
    // error at the current position, -3 for an unpaired surrogate.
    let n = lexscan self.binary() with longest {
      reb"^(?:[\x20\x21\x23-\x5b\x5d-\x7f]|[\xc2-\xdf][\x80-\xbf]|\xe0[\xa0-\xbf][\x80-\xbf]|[\xe1-\xec\xee\xef][\x80-\xbf]{2}|\xed[\x80-\x9f][\x80-\xbf]|\xf0[\x90-\xbf][\x80-\xbf]{2}|[\xf1-\xf3][\x80-\xbf]{3}|\xf4[\x80-\x8f][\x80-\xbf]{2}){1,64}" as s => {
        let decoded = decode_utf8(s)
        sb.write_string(decoded)
        self.advance(s.length())
        decoded.length()
      }
      reb"^\"" => {
        self.advance(1)
        -1
      }
      reb"^\\[\"\\/bfnrt]" as e => {
        sb.write_char(unescape(e[1].to_int()))
        self.advance(2)
        1
      }
      reb"^\\u[0-9a-fA-F]{4}" as u => {
        let c = hex4_b(u, 2)
        if c is (0xD800..<=0xDFFF) {
          -3
        } else {
          sb.write_char(c.unsafe_to_char())
          self.advance(6)
          1
        }
      }
      reb"^\\u[dD][89abAB][0-9a-fA-F]{2}\\u[dD][c-fC-F][0-9a-fA-F]{2}" as u => {
        let c = (hex4_b(u, 2) << 10) + hex4_b(u, 8) - 0x35fdc00
        sb.write_char(c.unsafe_to_char())
        self.advance(12)
        2
      }
      reb"^\\(?:u[0-9a-fA-F]{0,3})?" as e => {
        self.advance(e.length())
        -2
      }
      _ => -2
    }
    match n {
      -1 => break
      -2 => self.fail_here_b()
      -3 => raise UnpairedSurrogate(pos)
      _ => {
        len += n
        self.check_length(quote, len)
      }
    }
  }
  sb.to_string()
}

///|
/// Scans the rest of a number starting at `start`, whose first character
/// `first` (`-` or a digit) is consumed.
async fn Parser::slow_number_b(
  self : Parser,
  start : Position,
  first : Int32,
) -> Unit {
  let sb = StringBuilder()
  sb.write_char(first.unsafe_to_char())
  let mut lead = first
  if first == '-' {
    lead = self.slow_digit_b()
    if lead < 0 {
      self.fail_here_b()
    }
    sb.write_char(lead.unsafe_to_char())
  }
  let mut len = sb.to_string().length()
  if lead != '0' {
    len = self.slow_digits_b(sb, start, len)
  }
  // A fraction or exponent is taken only with its first digit, so a number
  // ends where the fast scanner's longest match ends; `1.` is `1` followed by
  // an unexpected `.`.
  let f = self.slow_fraction_b(sb)
  if f > 0 {
    len = self.slow_digits_b(sb, start, len + f)
  }
  let e = self.slow_exponent_b(sb)
  if e > 0 {
    len = self.slow_digits_b(sb, start, len + e)
  }
  self.check_length(start, len)
  self.scalar(number_value(sb.to_string()), true)
}

///|
/// Consumes one digit and returns it, or returns -1 and consumes nothing.
async fn Parser::slow_digit_b(self : Parser) -> Int32 {
  lexscan self.binary() with longest {
    reb"^[0-9]" as d => {
      self.advance(1)
      d.to_int()
    }
    _ => -1
  }
}

///|
/// Consumes digits into `sb` and returns the token length `len` plus the
/// number of digits.
async fn Parser::slow_digits_b(
  self : Parser,
  sb : StringBuilder,
  start : Position,
  len : Int32,
) -> Int32 {
  let mut len = len
  for ;; {
    let more = lexscan self.binary() with longest {
      reb"^[0-9]{1,64}" as d => {
        write_ascii(sb, d)
        self.advance(d.length())
        len += d.length()
        true
      }
      _ => false
    }
    if !more {
      break
    }
    self.check_length(start, len)
  }
  len
}

///|
/// Consumes `.` and one digit into `sb`; returns how many code units were
/// consumed.
async fn Parser::slow_fraction_b(self : Parser, sb : StringBuilder) -> Int32 {
  lexscan self.binary() with longest {
    reb"^\.[0-9]" as f => {
      write_ascii(sb, f)
      self.advance(2)
      2
    }
    _ => 0
  }
}

///|
/// Consumes `e` or `E`, an optional sign and one digit into `sb`; returns how
/// many code units were consumed.
async fn Parser::slow_exponent_b(self : Parser, sb : StringBuilder) -> Int32 {
  lexscan self.binary() with longest {
    reb"^[eE][+\-]?[0-9]" as e => {
      write_ascii(sb, e)
      self.advance(e.length())
      e.length()
    }
    _ => 0
  }
}

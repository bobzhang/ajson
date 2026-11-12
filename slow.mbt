// The slow scanner scans one token, or a bounded piece of one, per `lexscan`
// call. It implements the same state transitions as the fast scanner. It runs
// when the fast scanner's fallback is taken, to find and report the error, and
// for everything when `max_string_length` is set, since its pieces are
// bounded: at most 64 characters of whitespace, string or digits per scan.

///|
async fn Parser::slow_step(self : Parser) -> Unit {
  match self.state {
    Value => {
      let ws = self.slow_ws()
      self.slow_value(ws)
    }
    ArrayFirst => {
      self.slow_ws() |> ignore
      if self.slow_close_bracket() {
        self.close()
      } else {
        self.slow_value(1)
      }
    }
    ArrayNext => {
      self.slow_ws() |> ignore
      let pos = self.pos()
      match self.slow_punct() {
        ']' => self.close()
        ',' => {
          self.slow_ws() |> ignore
          self.slow_value(1)
        }
        c => self.unexpected(pos, c)
      }
    }
    ObjectFirst => {
      self.slow_ws() |> ignore
      let pos = self.pos()
      match self.slow_punct() {
        '}' => self.close()
        '"' => self.slow_member(pos)
        c => self.unexpected(pos, c)
      }
    }
    ObjectNext => {
      self.slow_ws() |> ignore
      let pos = self.pos()
      match self.slow_punct() {
        '}' => self.close()
        ',' => {
          self.slow_ws() |> ignore
          let pos = self.pos()
          match self.slow_punct() {
            '"' => self.slow_member(pos)
            c => self.unexpected(pos, c)
          }
        }
        c => self.unexpected(pos, c)
      }
    }
    TopEnd =>
      if self.multiple_values {
        self.state = Value
      } else {
        self.slow_ws() |> ignore
        if self.slow_eof() {
          self.state = Finished
        } else {
          self.fail_here()
        }
      }
    Finished => ()
  }
}

///|
/// Reports `c`, consumed by `slow_punct` at `pos`, as unexpected; or, if
/// `slow_punct` consumed nothing (`c` is -1), the next character.
async fn[T] Parser::unexpected(self : Parser, pos : Position, c : Int32) -> T {
  if c < 0 {
    self.fail_here()
  } else {
    raise UnexpectedChar(pos, c.unsafe_to_char())
  }
}

///|
/// Raises the error for the next character, or for the end of the input.
async fn[T] Parser::fail_here(self : Parser) -> T {
  let pos = self.pos()
  let c = lexscan self.lexbuf with longest {
    re"^[\u{0}-\u{10FFFF}]" as c => Some(c)
    _ => None
  }
  match c {
    Some(c) => raise UnexpectedChar(pos, c)
    None => raise UnexpectedEof(pos)
  }
}

///|
/// Skips whitespace and returns the number of code units skipped.
async fn Parser::slow_ws(self : Parser) -> Int32 {
  let start = self.offset
  for ;; {
    let more = lexscan self.lexbuf with longest {
      re"^[ \t\r]{1,64}" as w => {
        self.advance(w.length())
        true
      }
      re"^\n" => {
        self.advance_text("\n")
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
async fn Parser::slow_eof(self : Parser) -> Bool {
  lexscan self.lexbuf with longest {
    re"^$" => true
    _ => false
  }
}

///|
async fn Parser::slow_close_bracket(self : Parser) -> Bool {
  lexscan self.lexbuf with longest {
    re"^\]" => {
      self.advance(1)
      true
    }
    _ => false
  }
}

///|
/// Consumes one of `,:]}"` and returns it, or returns -1 and consumes nothing.
async fn Parser::slow_punct(self : Parser) -> Int32 {
  let c = lexscan self.lexbuf with longest {
    re"^," => ','.to_int()
    re"^:" => ':'.to_int()
    re"^\]" => ']'.to_int()
    re"^[}]" => '}'.to_int()
    re"^\"" => '"'.to_int()
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
async fn Parser::slow_member(self : Parser, quote : Position) -> Unit {
  let key = self.slow_string(quote)
  self.pending.push(Key(key))
  self.slow_ws() |> ignore
  let pos = self.pos()
  match self.slow_punct() {
    ':' => self.state = Value
    c => self.unexpected(pos, c)
  }
}

///|
/// Scans a value after `ws` code units of whitespace. At the top level of a
/// multi-value stream the end of the input is accepted instead.
async fn Parser::slow_value(self : Parser, ws : Int32) -> Unit {
  let pos = self.pos()
  // A code for what starts here: the character for a container, a string or
  // a number; 't', 'f' or 'n' for a whole literal; 0 for the prefix of a
  // literal; -2 for the end of the input; -1 for anything else.
  let kind = lexscan self.lexbuf with longest {
    re"^[{]" => '{'.to_int()
    re"^\[" => '['.to_int()
    re"^\"" => '"'.to_int()
    re"^true" => 't'.to_int()
    re"^false" => 'f'.to_int()
    re"^null" => 'n'.to_int()
    re"^-" => '-'.to_int()
    re"^[0-9]" as d => d.to_int()
    re"^(?:t(?:ru?)?|f(?:a(?:ls?)?)?|n(?:ul?)?)" as p => {
      self.advance(p.length())
      0
    }
    re"^$" => -2
    _ => -1
  }
  if kind == -2 && self.stack.is_empty() && self.multiple_values {
    self.state = Finished
    return
  }
  if kind <= 0 {
    self.fail_here()
  }
  if self.multiple_values {
    self.check_separator(ws, kind.unsafe_to_char())
  }
  match kind {
    '{' | '[' => {
      self.open(kind == '{', pos)
      self.advance(1)
    }
    '"' => {
      self.advance(1)
      let s = self.slow_string(pos)
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
      self.slow_number(pos, kind)
    }
  }
}

///|
/// Checks the length limit for a token starting at `start`.
fn Parser::check_length(
  self : Parser,
  start : Position,
  len : Int32,
) -> Unit raise ParseError {
  if self.max_string_length >= 0 && len > self.max_string_length {
    raise TooLong(start, self.max_string_length)
  }
}

///|
/// Scans the rest of a string after its opening quote at `quote` and returns
/// its decoded contents.
async fn Parser::slow_string(self : Parser, quote : Position) -> String {
  let sb = StringBuilder()
  let mut len = 0
  for ;; {
    let pos = self.pos()
    // The number of code units added, or -1 at the closing quote, -2 for an
    // error at the current position, -3 for an unpaired surrogate.
    let n = lexscan self.lexbuf with longest {
      re"^[^\"\\\u{0}-\u{1f}]{1,64}" as s => {
        sb.write_view(s)
        self.advance(s.length())
        s.length()
      }
      re"^\"" => {
        self.advance(1)
        -1
      }
      re"^\\[\"\\/bfnrt]" as e => {
        sb.write_char(unescape(e.unsafe_get(1)))
        self.advance(2)
        1
      }
      re"^\\u[0-9a-fA-F]{4}" as u => {
        let c = hex4(u, 2)
        if c is (0xD800..<=0xDFFF) {
          -3
        } else {
          sb.write_char(c.unsafe_to_char())
          self.advance(6)
          1
        }
      }
      re"^\\u[dD][89abAB][0-9a-fA-F]{2}\\u[dD][c-fC-F][0-9a-fA-F]{2}" as u => {
        let c = (hex4(u, 2) << 10) + hex4(u, 8) - 0x35fdc00
        sb.write_char(c.unsafe_to_char())
        self.advance(12)
        2
      }
      re"^\\(?:u[0-9a-fA-F]{0,3})?" as e => {
        self.advance(e.length())
        -2
      }
      _ => -2
    }
    match n {
      -1 => break
      -2 => self.fail_here()
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
async fn Parser::slow_number(
  self : Parser,
  start : Position,
  first : Int32,
) -> Unit {
  let sb = StringBuilder()
  sb.write_char(first.unsafe_to_char())
  let mut lead = first
  if first == '-' {
    lead = self.slow_digit()
    if lead < 0 {
      self.fail_here()
    }
    sb.write_char(lead.unsafe_to_char())
  }
  let mut len = sb.to_string().length()
  if lead != '0' {
    len = self.slow_digits(sb, start, len)
  }
  // A fraction or exponent is taken only with its first digit, so a number
  // ends where the fast scanner's longest match ends; `1.` is `1` followed by
  // an unexpected `.`.
  let f = self.slow_fraction(sb)
  if f > 0 {
    len = self.slow_digits(sb, start, len + f)
  }
  let e = self.slow_exponent(sb)
  if e > 0 {
    len = self.slow_digits(sb, start, len + e)
  }
  self.check_length(start, len)
  self.scalar(number_value(sb.to_string()), true)
}

///|
/// Consumes one digit and returns it, or returns -1 and consumes nothing.
async fn Parser::slow_digit(self : Parser) -> Int32 {
  lexscan self.lexbuf with longest {
    re"^[0-9]" as d => {
      self.advance(1)
      d.to_int()
    }
    _ => -1
  }
}

///|
/// Consumes digits into `sb` and returns the token length `len` plus the
/// number of digits.
async fn Parser::slow_digits(
  self : Parser,
  sb : StringBuilder,
  start : Position,
  len : Int32,
) -> Int32 {
  let mut len = len
  for ;; {
    let more = lexscan self.lexbuf with longest {
      re"^[0-9]{1,64}" as d => {
        sb.write_view(d)
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
async fn Parser::slow_fraction(self : Parser, sb : StringBuilder) -> Int32 {
  lexscan self.lexbuf with longest {
    re"^\.[0-9]" as f => {
      sb.write_view(f)
      self.advance(2)
      2
    }
    _ => 0
  }
}

///|
/// Consumes `e` or `E`, an optional sign and one digit into `sb`; returns how
/// many code units were consumed.
async fn Parser::slow_exponent(self : Parser, sb : StringBuilder) -> Int32 {
  lexscan self.lexbuf with longest {
    re"^[eE][+\-]?[0-9]" as e => {
      sb.write_view(e)
      self.advance(e.length())
      e.length()
    }
    _ => 0
  }
}

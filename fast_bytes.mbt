// The fast scanner for UTF-8 bytes input: `fast.mbt` with `reb` regexes.
// The string regex accepts only well-formed UTF-8, so a scanned string is
// valid; offsets count bytes.

///|
/// State `Value` or `ArrayFirst`: whitespace, then a value.
async fn Parser::scan_value_b(self : Parser) -> Unit {
  let matched = lexscan self.binary() with longest {
    (reb"^[ \t\r\n]*" as w) +
    (
      reb"\"(?:(?:[\x20\x21\x23-\x5b\x5d-\x7f]|[\xc2-\xdf][\x80-\xbf]|\xe0[\xa0-\xbf][\x80-\xbf]|[\xe1-\xec\xee\xef][\x80-\xbf]{2}|\xed[\x80-\x9f][\x80-\xbf]|\xf0[\x90-\xbf][\x80-\xbf]{2}|[\xf1-\xf3][\x80-\xbf]{3}|\xf4[\x80-\x8f][\x80-\xbf]{2})|\\[\"\\/bfnrt]|\\u[0-9a-fA-F]{4})*\"|-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+\-]?[0-9]+)?|true|false|null|[{][ \t\r\n]*[}]|\[[ \t\r\n]*\]|[{]|\[" as v
    ) => {
      self.advance_text_b(w)
      self.on_value_b(v, w.length())
      true
    }
    _ => false
  }
  if !matched {
    self.slow_step_b()
  }
}

///|
/// State `ArrayNext`: `]`, or `,` and the next element.
async fn Parser::scan_array_next_b(self : Parser) -> Unit {
  let matched = lexscan self.binary() with longest {
    reb"^[ \t\r\n]*\]" as w => {
      self.advance_text_b(w)
      self.close()
      true
    }
    (reb"^[ \t\r\n]*,[ \t\r\n]*" as w) +
    (
      reb"\"(?:(?:[\x20\x21\x23-\x5b\x5d-\x7f]|[\xc2-\xdf][\x80-\xbf]|\xe0[\xa0-\xbf][\x80-\xbf]|[\xe1-\xec\xee\xef][\x80-\xbf]{2}|\xed[\x80-\x9f][\x80-\xbf]|\xf0[\x90-\xbf][\x80-\xbf]{2}|[\xf1-\xf3][\x80-\xbf]{3}|\xf4[\x80-\x8f][\x80-\xbf]{2})|\\[\"\\/bfnrt]|\\u[0-9a-fA-F]{4})*\"|-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+\-]?[0-9]+)?|true|false|null|[{][ \t\r\n]*[}]|\[[ \t\r\n]*\]|[{]|\[" as v
    ) => {
      self.advance_text_b(w)
      self.on_value_b(v, w.length())
      true
    }
    _ => false
  }
  if !matched {
    self.slow_step_b()
  }
}

///|
/// State `ObjectFirst`: the first member. An empty object never gets here
/// from the fast scanner, since `{}` is scanned as one value.
async fn Parser::scan_member_b(self : Parser) -> Unit {
  let matched = lexscan self.binary() with longest {
    (reb"^[ \t\r\n]*\"" as h1) +
    (
      reb"(?:(?:[\x20\x21\x23-\x5b\x5d-\x7f]|[\xc2-\xdf][\x80-\xbf]|\xe0[\xa0-\xbf][\x80-\xbf]|[\xe1-\xec\xee\xef][\x80-\xbf]{2}|\xed[\x80-\x9f][\x80-\xbf]|\xf0[\x90-\xbf][\x80-\xbf]{2}|[\xf1-\xf3][\x80-\xbf]{3}|\xf4[\x80-\x8f][\x80-\xbf]{2})|\\[\"\\/bfnrt]|\\u[0-9a-fA-F]{4})*" as k
    ) +
    (reb"\"[ \t\r\n]*:[ \t\r\n]*" as h2) +
    (
      reb"\"(?:(?:[\x20\x21\x23-\x5b\x5d-\x7f]|[\xc2-\xdf][\x80-\xbf]|\xe0[\xa0-\xbf][\x80-\xbf]|[\xe1-\xec\xee\xef][\x80-\xbf]{2}|\xed[\x80-\x9f][\x80-\xbf]|\xf0[\x90-\xbf][\x80-\xbf]{2}|[\xf1-\xf3][\x80-\xbf]{3}|\xf4[\x80-\x8f][\x80-\xbf]{2})|\\[\"\\/bfnrt]|\\u[0-9a-fA-F]{4})*\"|-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+\-]?[0-9]+)?|true|false|null|[{][ \t\r\n]*[}]|\[[ \t\r\n]*\]|[{]|\[" as v
    ) => {
      self.on_member_b(h1, k, h2, v)
      true
    }
    _ => false
  }
  if !matched {
    self.slow_step_b()
  }
}

///|
/// State `ObjectNext`: `}`, or `,` and the next member.
async fn Parser::scan_object_next_b(self : Parser) -> Unit {
  let matched = lexscan self.binary() with longest {
    reb"^[ \t\r\n]*[}]" as w => {
      self.advance_text_b(w)
      self.close()
      true
    }
    (reb"^[ \t\r\n]*,[ \t\r\n]*\"" as h1) +
    (
      reb"(?:(?:[\x20\x21\x23-\x5b\x5d-\x7f]|[\xc2-\xdf][\x80-\xbf]|\xe0[\xa0-\xbf][\x80-\xbf]|[\xe1-\xec\xee\xef][\x80-\xbf]{2}|\xed[\x80-\x9f][\x80-\xbf]|\xf0[\x90-\xbf][\x80-\xbf]{2}|[\xf1-\xf3][\x80-\xbf]{3}|\xf4[\x80-\x8f][\x80-\xbf]{2})|\\[\"\\/bfnrt]|\\u[0-9a-fA-F]{4})*" as k
    ) +
    (reb"\"[ \t\r\n]*:[ \t\r\n]*" as h2) +
    (
      reb"\"(?:(?:[\x20\x21\x23-\x5b\x5d-\x7f]|[\xc2-\xdf][\x80-\xbf]|\xe0[\xa0-\xbf][\x80-\xbf]|[\xe1-\xec\xee\xef][\x80-\xbf]{2}|\xed[\x80-\x9f][\x80-\xbf]|\xf0[\x90-\xbf][\x80-\xbf]{2}|[\xf1-\xf3][\x80-\xbf]{3}|\xf4[\x80-\x8f][\x80-\xbf]{2})|\\[\"\\/bfnrt]|\\u[0-9a-fA-F]{4})*\"|-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+\-]?[0-9]+)?|true|false|null|[{][ \t\r\n]*[}]|\[[ \t\r\n]*\]|[{]|\[" as v
    ) => {
      self.on_member_b(h1, k, h2, v)
      true
    }
    _ => false
  }
  if !matched {
    self.slow_step_b()
  }
}

///|
/// Handles a member scanned as `h1` (up to the opening quote), the raw
/// property name `k`, `h2` (closing quote to the value) and the value `v`.
fn Parser::on_member_b(
  self : Parser,
  h1 : BytesView,
  k : BytesView,
  h2 : BytesView,
  v : BytesView,
) -> Unit raise ParseError {
  self.advance_text_b(h1)
  let key = self.decode_bytes_string(k, self.offset)
  self.advance(k.length())
  self.advance_text_b(h2)
  self.pending.push(Key(key))
  self.on_value_b(v, 1)
}

///|
/// Handles a value `v` matched by the value regex at the current position,
/// after `ws` code units of whitespace.
fn Parser::on_value_b(
  self : Parser,
  v : BytesView,
  ws : Int32,
) -> Unit raise ParseError {
  let c = v[0].to_int()
  if self.multiple_values {
    self.check_separator(ws, c.unsafe_to_char())
  }
  match c {
    '"' => {
      let s = self.decode_bytes_string(v[1:v.length() - 1], self.offset + 1)
      self.advance(v.length())
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
    '{' | '[' => {
      self.open(c == '{'.to_int(), self.pos())
      if v.length() == 1 {
        self.advance(1)
      } else {
        self.advance_text_b(v)
        self.close()
      }
    }
    _ => {
      let value = number_value_bytes(v)
      self.advance(v.length())
      self.scalar(value, true)
    }
  }
}

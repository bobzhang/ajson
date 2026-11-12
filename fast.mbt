// The fast scanner. Each function below is one `lexscan` call that consumes a
// whole group of tokens: leading whitespace, punctuation, a property name and
// a value. A value is a whole scalar, an empty `{}` or `[]`, or the opening
// bracket of a non-empty container. The regular expressions accept exactly the
// valid groups, so the fallback case means the input is malformed somewhere
// in the group. The fallback consumes nothing and hands over to the slow
// scanner (`slow.mbt`), which scans the same group token by token and reports
// the precise error.
//
// The captures cover the whole match, so the parser can keep its position:
// whitespace pieces may contain line breaks, while strings, numbers and
// literals cannot.
//
// The value regex, shared by every group:
//
//   \"(?:[^\"\\\u{0}-\u{1f}]|\\[\"\\/bfnrt]|\\u[0-9a-fA-F]{4})*\"
//   | -?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+\-]?[0-9]+)?
//   | true | false | null
//   | \{[ \t\r\n]*\} | \[[ \t\r\n]*\] | \{ | \[
//
// The number regex is the one of core's lexscan JSON parser.

///|
/// State `Value` or `ArrayFirst`: whitespace, then a value.
async fn Parser::scan_value(self : Parser) -> Unit {
  let matched = lexscan self.text() with longest {
    (re"^[ \t\r\n]*" as w) +
    (
      re"\"(?:[^\"\\\u{0}-\u{1f}]|\\[\"\\/bfnrt]|\\u[0-9a-fA-F]{4})*\"|-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+\-]?[0-9]+)?|true|false|null|[{][ \t\r\n]*[}]|\[[ \t\r\n]*\]|[{]|\[" as v
    ) => {
      self.advance_text(w)
      self.on_value(v, w.length())
      true
    }
    _ => false
  }
  if !matched {
    self.slow_step()
  }
}

///|
/// State `ArrayNext`: `]`, or `,` and the next element.
async fn Parser::scan_array_next(self : Parser) -> Unit {
  let matched = lexscan self.text() with longest {
    re"^[ \t\r\n]*\]" as w => {
      self.advance_text(w)
      self.close()
      true
    }
    (re"^[ \t\r\n]*,[ \t\r\n]*" as w) +
    (
      re"\"(?:[^\"\\\u{0}-\u{1f}]|\\[\"\\/bfnrt]|\\u[0-9a-fA-F]{4})*\"|-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+\-]?[0-9]+)?|true|false|null|[{][ \t\r\n]*[}]|\[[ \t\r\n]*\]|[{]|\[" as v
    ) => {
      self.advance_text(w)
      self.on_value(v, w.length())
      true
    }
    _ => false
  }
  if !matched {
    self.slow_step()
  }
}

///|
/// State `ObjectFirst`: the first member. An empty object never gets here
/// from the fast scanner, since `{}` is scanned as one value.
async fn Parser::scan_member(self : Parser) -> Unit {
  let matched = lexscan self.text() with longest {
    (re"^[ \t\r\n]*\"" as h1) +
    (re"(?:[^\"\\\u{0}-\u{1f}]|\\[\"\\/bfnrt]|\\u[0-9a-fA-F]{4})*" as k) +
    (re"\"[ \t\r\n]*:[ \t\r\n]*" as h2) +
    (
      re"\"(?:[^\"\\\u{0}-\u{1f}]|\\[\"\\/bfnrt]|\\u[0-9a-fA-F]{4})*\"|-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+\-]?[0-9]+)?|true|false|null|[{][ \t\r\n]*[}]|\[[ \t\r\n]*\]|[{]|\[" as v
    ) => {
      self.on_member(h1, k, h2, v)
      true
    }
    _ => false
  }
  if !matched {
    self.slow_step()
  }
}

///|
/// State `ObjectNext`: `}`, or `,` and the next member.
async fn Parser::scan_object_next(self : Parser) -> Unit {
  let matched = lexscan self.text() with longest {
    re"^[ \t\r\n]*[}]" as w => {
      self.advance_text(w)
      self.close()
      true
    }
    (re"^[ \t\r\n]*,[ \t\r\n]*\"" as h1) +
    (re"(?:[^\"\\\u{0}-\u{1f}]|\\[\"\\/bfnrt]|\\u[0-9a-fA-F]{4})*" as k) +
    (re"\"[ \t\r\n]*:[ \t\r\n]*" as h2) +
    (
      re"\"(?:[^\"\\\u{0}-\u{1f}]|\\[\"\\/bfnrt]|\\u[0-9a-fA-F]{4})*\"|-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+\-]?[0-9]+)?|true|false|null|[{][ \t\r\n]*[}]|\[[ \t\r\n]*\]|[{]|\[" as v
    ) => {
      self.on_member(h1, k, h2, v)
      true
    }
    _ => false
  }
  if !matched {
    self.slow_step()
  }
}

///|
/// Handles a member scanned as `h1` (up to the opening quote), the raw
/// property name `k`, `h2` (closing quote to the value) and the value `v`.
fn Parser::on_member(
  self : Parser,
  h1 : StringView,
  k : StringView,
  h2 : StringView,
  v : StringView,
) -> Unit raise ParseError {
  self.advance_text(h1)
  let key = self.decode_string(k, self.offset)
  self.advance(k.length())
  self.advance_text(h2)
  self.pending.push(Key(key))
  self.on_value(v, 1)
}

///|
/// Handles a value `v` matched by the value regex at the current position,
/// after `ws` code units of whitespace.
fn Parser::on_value(
  self : Parser,
  v : StringView,
  ws : Int32,
) -> Unit raise ParseError {
  let c = v.unsafe_get(0)
  if self.multiple_values {
    self.check_separator(ws, c.to_int().unsafe_to_char())
  }
  match c {
    '"' => {
      let s = self.decode_string(v[1:v.length() - 1], self.offset + 1)
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
      self.open(c == '{', self.pos())
      if v.length() == 1 {
        self.advance(1)
      } else {
        self.advance_text(v)
        self.close()
      }
    }
    _ => {
      let value = number_value(v)
      self.advance(v.length())
      self.scalar(value, true)
    }
  }
}

///|
/// The input: UTF-16 text or UTF-8 bytes.
priv enum Input {
  Text(@lexbuf.AsyncLexbuf)
  Binary(@lexbuf.AsyncBytesLexbuf)
}

///|
fn Parser::text(self : Parser) -> @lexbuf.AsyncLexbuf {
  guard self.input is Text(lexbuf) else { abort("unreachable: not text input") }
  lexbuf
}

///|
fn Parser::binary(self : Parser) -> @lexbuf.AsyncBytesLexbuf {
  guard self.input is Binary(lexbuf) else {
    abort("unreachable: not bytes input")
  }
  lexbuf
}

///|
/// What the parser expects next.
#derive(Eq)
priv enum State {
  /// A value: at the top level, after `:`, or after `,` in an array.
  Value
  /// After `[`: the first element or `]`.
  ArrayFirst
  /// After an array element: `,` or `]`.
  ArrayNext
  /// After `{`: the first member or `}`.
  ObjectFirst
  /// After a member value: `,` or `}`.
  ObjectNext
  /// After a complete top-level value.
  TopEnd
  /// The input is exhausted.
  Finished
}

///|
/// An asynchronous pull parser for JSON read from an `@lexbuf.AsyncLexbuf`
/// (UTF-16 text) or an `@lexbuf.AsyncBytesLexbuf` (UTF-8 bytes).
///
/// The parser keeps one entry per open container (`true` for an object), so
/// its memory is proportional to the nesting depth, not to the document size.
/// Tokens are scanned whole by `lexscan`, so a single token, such as a long
/// string, is buffered in full unless `max_string_length` is set.
///
/// After a syntax error or an error raised by the input source, every later
/// call raises the same error again. Events before a syntax error are returned
/// first. When the source raises, the events of the token group being scanned
/// may be lost. After a cancellation, later calls raise `Interrupted`.
pub struct Parser {
  priv input : Input
  priv max_depth : Int32
  priv max_string_length : Int32
  priv multiple_values : Bool
  priv stack : Array[Bool]
  priv mut state : State
  priv pending : Array[Event]
  priv mut pending_head : Int32
  priv mut offset : Int32
  priv mut line : Int32
  priv mut line_start : Int32
  priv mut need_separator : Bool
  priv mut error : Error?
}

///|
/// Creates a parser reading from `lexbuf`.
///
/// - `max_depth`: the deepest nesting of objects and arrays accepted. The
///   default matches `@json.parse`.
/// - `max_string_length`: if set, strings, property names and number literals
///   longer than this many UTF-16 code units are rejected with `TooLong`. The
///   parser then scans a token in pieces of at most 64 characters, so its
///   memory is bounded by the depth, about one input chunk and the token being
///   decoded (at most the limit). This mode is slower.
/// - `multiple_values`: if `true`, the input is a sequence of JSON values, such
///   as newline-delimited JSON or concatenated documents, separated by optional
///   whitespace; a top-level number, `true`, `false` or `null` must be followed
///   by whitespace or the end of input. The default expects exactly one value.
pub fn Parser::new(
  lexbuf : @lexbuf.AsyncLexbuf,
  max_depth~ : Int32 = 1024,
  max_string_length? : Int32,
  multiple_values~ : Bool = false,
) -> Parser {
  {
    input: Text(lexbuf),
    max_depth,
    max_string_length: match max_string_length {
      Some(n) => if n < 0 { 0 } else { n }
      None => -1
    },
    multiple_values,
    stack: [],
    state: Value,
    pending: [],
    pending_head: 0,
    offset: 0,
    line: 1,
    line_start: 0,
    need_separator: false,
    error: None,
  }
}

///|
/// Creates a parser reading UTF-8 bytes from `lexbuf`. Positions count bytes.
/// Malformed UTF-8 is rejected with `InvalidUtf8`. The options are those of
/// `Parser::new`; `max_string_length` still counts UTF-16 code units of the
/// decoded strings.
pub fn Parser::new_bytes(
  lexbuf : @lexbuf.AsyncBytesLexbuf,
  max_depth~ : Int32 = 1024,
  max_string_length? : Int32,
  multiple_values~ : Bool = false,
) -> Parser {
  {
    ..Parser::new(
      empty_text(),
      max_depth~,
      max_string_length?,
      multiple_values~,
    ),
    input: Binary(lexbuf),
  }
}

///|
fn empty_text() -> @lexbuf.AsyncLexbuf {
  @lexbuf.AsyncLexbuf::from_fn(() => None)
}

///|
/// Creates a parser reading UTF-8 bytes from `reader`, for example
/// `@stdio.stdin`. The options are those of `Parser::new_bytes`.
pub fn[R : @io.BinaryReader] Parser::from_binary_reader(
  reader : R,
  max_depth~ : Int32 = 1024,
  max_string_length? : Int32,
  multiple_values~ : Bool = false,
) -> Parser {
  Parser::new_bytes(
    @lexbuf.AsyncBytesLexbuf::from_fn(() => reader.read()),
    max_depth~,
    max_string_length?,
    multiple_values~,
  )
}

///|
/// Creates a parser reading text chunks from `reader`, for example
/// `@stdio.stdin.text`. The options are those of `Parser::new`.
pub fn[R : @io.TextReader] Parser::from_reader(
  reader : R,
  max_depth~ : Int32 = 1024,
  max_string_length? : Int32,
  multiple_values~ : Bool = false,
) -> Parser {
  Parser::new(
    @lexbuf.AsyncLexbuf::from_fn(() => reader.read()),
    max_depth~,
    max_string_length?,
    multiple_values~,
  )
}

///|
/// The position of the next unconsumed input. Events already scanned but not
/// yet returned by `next_event` are behind this position.
pub fn Parser::position(self : Parser) -> Position {
  {
    offset: self.offset,
    line: self.line,
    column: self.offset - self.line_start,
  }
}

///|
/// The number of objects and arrays open after the events returned so far,
/// counting events that are scanned but not yet returned.
pub fn Parser::depth(self : Parser) -> Int32 {
  self.stack.length()
}

///|
/// Returns the next event, or `None` at the end of the input.
pub async fn Parser::next_event(self : Parser) -> Event? {
  if self.pending_head < self.pending.length() {
    return Some(self.take_pending())
  }
  if self.error is Some(e) {
    raise e
  }
  // A step interrupted by an error that is not caught below, such as a
  // cancellation, leaves the input in an unknown state.
  // Events it queued are dropped: they may start a group that will never be
  // completed.
  errdefer (if self.error is None {
    self.error = Some(Interrupted)
    self.pending.clear()
    self.pending_head = 0
  })
  while self.state != Finished {
    let failed = try {
      match self.input {
        Text(_) =>
          if self.max_string_length >= 0 {
            self.slow_step()
          } else {
            match self.state {
              Value | ArrayFirst => self.scan_value()
              ArrayNext => self.scan_array_next()
              ObjectFirst => self.scan_member()
              ObjectNext => self.scan_object_next()
              TopEnd | Finished => self.slow_step()
            }
          }
        Binary(_) =>
          if self.max_string_length >= 0 {
            self.slow_step_b()
          } else {
            match self.state {
              Value | ArrayFirst => self.scan_value_b()
              ArrayNext => self.scan_array_next_b()
              ObjectFirst => self.scan_member_b()
              ObjectNext => self.scan_object_next_b()
              TopEnd | Finished => self.slow_step_b()
            }
          }
      }
      None
    } catch {
      e => Some(e)
    }
    if failed is Some(e) {
      self.error = Some(e)
    }
    // Events scanned before an error are still returned first.
    if self.pending_head < self.pending.length() {
      return Some(self.take_pending())
    }
    if failed is Some(e) {
      raise e
    }
  }
  None
}

///|
fn Parser::take_pending(self : Parser) -> Event {
  let event = self.pending[self.pending_head]
  self.pending_head += 1
  if self.pending_head == self.pending.length() {
    self.pending.clear()
    self.pending_head = 0
  }
  event
}

///|
/// Returns the next complete value.
///
/// At the top level this is the next document. Inside an array it is the
/// next element. It returns `None` at the end of the input, or when the
/// enclosing array or object ends (the end event is consumed). Inside an
/// object, where the next event is a `Key`, use `next_member` instead; calling
/// `next_value` there aborts.
pub async fn Parser::next_value(self : Parser) -> Json? {
  match self.next_event() {
    None | Some(EndArray | EndObject) => None
    Some(Key(_)) =>
      abort("Parser::next_value: the next event is a key; use next_member")
    Some(first) => Some(self.build_value(first))
  }
}

///|
/// Returns the next member of the enclosing object as a key and its complete
/// value, or `None` when the object ends (the `EndObject` event is consumed).
/// Aborts unless the next event is a `Key` or `EndObject`.
pub async fn Parser::next_member(self : Parser) -> (String, Json)? {
  match self.next_event() {
    Some(EndObject) => None
    Some(Key(key)) => {
      guard self.next_event() is Some(first) else {
        abort("unreachable: a key is always followed by a value")
      }
      Some((key, self.build_value(first)))
    }
    _ => abort("Parser::next_member: not inside an object")
  }
}

///|
/// Skips the next complete value without building it, with the same contract
/// as `next_value`: returns `false` at the end of the input or when the
/// enclosing container ends. Aborts if the next event is a `Key`.
pub async fn Parser::skip_value(self : Parser) -> Bool {
  let mut open = match self.next_event() {
    None | Some(EndArray | EndObject) => return false
    Some(Key(_)) => abort("Parser::skip_value: the next event is a key")
    Some(StartArray | StartObject) => 1
    Some(Value(_)) => 0
  }
  while open > 0 {
    match self.next_event() {
      Some(StartArray | StartObject) => open += 1
      Some(EndArray | EndObject) => open -= 1
      Some(_) => ()
      None =>
        abort("unreachable: the input ended inside a value without an error")
    }
  }
  true
}

///|
/// Calls `f` with each remaining value, as returned by `next_value`.
pub async fn Parser::each_value(
  self : Parser,
  f : async (Json) -> Unit,
) -> Unit {
  while self.next_value() is Some(value) {
    f(value)
  }
}

///|
/// A container being built by `build_value`.
priv enum Builder {
  ArrayBuilder(Array[Json])
  ObjectBuilder(Map[String, Json], mut key~ : String)
}

///|
/// Builds the value that starts with `first`, reading the rest of its events.
/// Uses an explicit stack, so deep nesting does not deepen the call stack.
async fn Parser::build_value(self : Parser, first : Event) -> Json {
  let stack : Array[Builder] = []
  let mut event = first
  for ;; {
    let value = match event {
      Value(v) => v
      StartArray => {
        stack.push(ArrayBuilder([]))
        event = self.next_event_in_value()
        continue
      }
      StartObject => {
        stack.push(ObjectBuilder(Map([]), key=""))
        event = self.next_event_in_value()
        continue
      }
      Key(k) => {
        guard stack.last() is Some(ObjectBuilder(_) as b) else {
          abort("unreachable: key outside an object")
        }
        b.key = k
        event = self.next_event_in_value()
        continue
      }
      EndArray =>
        match stack.pop() {
          Some(ArrayBuilder(elements)) => Json::array(elements)
          _ => abort("unreachable: unbalanced array")
        }
      EndObject =>
        match stack.pop() {
          Some(ObjectBuilder(members, ..)) => Json::object(members)
          _ => abort("unreachable: unbalanced object")
        }
    }
    match stack.last() {
      None => return value
      Some(ArrayBuilder(elements)) => elements.push(value)
      Some(ObjectBuilder(members, key~)) => members[key] = value
    }
    event = self.next_event_in_value()
  }
}

///|
/// Events already scanned are taken without an async call.
async fn Parser::next_event_in_value(self : Parser) -> Event {
  if self.pending_head < self.pending.length() {
    return self.take_pending()
  }
  guard self.next_event() is Some(event) else {
    abort("unreachable: the input ended inside a value without an error")
  }
  event
}

///|
/// The current position, for errors.
fn Parser::pos(self : Parser) -> Position {
  self.position()
}

///|
/// Advances over `n` code units that contain no line break.
fn Parser::advance(self : Parser, n : Int32) -> Unit {
  self.offset += n
}

///|
/// Advances over `text`, which may contain line breaks.
fn Parser::advance_text(self : Parser, text : StringView) -> Unit {
  let base = self.offset
  for i in 0..<text.length() {
    if text.unsafe_get(i) == '\n' {
      self.line += 1
      self.line_start = base + i + 1
    }
  }
  self.offset = base + text.length()
}

///|
/// Advances over a line break.
fn Parser::newline(self : Parser) -> Unit {
  self.offset += 1
  self.line += 1
  self.line_start = self.offset
}

///|
/// Called after a complete value: decides what comes next.
fn Parser::value_done(self : Parser) -> Unit {
  self.state = match self.stack.last() {
    None => TopEnd
    Some(true) => ObjectNext
    Some(false) => ArrayNext
  }
}

///|
/// Opens an object (`true`) or array at `pos`, checking the depth limit.
fn Parser::open(
  self : Parser,
  is_object : Bool,
  pos : Position,
) -> Unit raise ParseError {
  if self.stack.length() >= self.max_depth {
    raise DepthLimitExceeded(pos, self.max_depth)
  }
  self.stack.push(is_object)
  if is_object {
    self.pending.push(StartObject)
    self.state = ObjectFirst
  } else {
    self.pending.push(StartArray)
    self.state = ArrayFirst
  }
}

///|
/// Closes the innermost container.
fn Parser::close(self : Parser) -> Unit {
  match self.stack.pop() {
    Some(true) => self.pending.push(EndObject)
    Some(false) => self.pending.push(EndArray)
    None => abort("unreachable: close at the top level")
  }
  self.value_done()
}

///|
/// Emits a complete scalar value.
fn Parser::scalar(self : Parser, value : Json, needs_separator : Bool) -> Unit {
  self.pending.push(Value(value))
  if self.stack.is_empty() && self.multiple_values {
    self.need_separator = needs_separator
  }
  self.value_done()
}

///|
/// At the top level of a multi-value stream, checks that whitespace separates
/// a number or literal from the next value. `ws` is the length of the
/// whitespace before the value, which starts with `c` at the current position.
fn Parser::check_separator(
  self : Parser,
  ws : Int32,
  c : Char,
) -> Unit raise ParseError {
  if self.need_separator && ws == 0 && self.stack.is_empty() {
    raise UnexpectedChar(self.pos(), c)
  }
  self.need_separator = false
}

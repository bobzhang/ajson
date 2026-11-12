///|
/// A parse event. Scalars arrive whole as `Value`; objects and arrays arrive
/// as a start event, their contents, and an end event. Inside an object every
/// member is a `Key` followed by the events of its value.
#derive(Eq, Debug, ToJson)
pub(all) enum Event {
  StartObject
  EndObject
  StartArray
  EndArray
  Key(String)
  /// A string, number, `true`, `false` or `null`.
  Value(Json)
}

///|
/// A position in the input. `offset` counts UTF-16 code units from the start
/// of the stream. `line` is 1-based and `column` is 0-based, as in
/// `@json.Position`; `column` counts UTF-16 code units from the start of the
/// line.
#derive(Eq, Debug, ToJson)
pub(all) struct Position {
  offset : Int32
  line : Int32
  column : Int32
}

///|
pub impl Show for Position with fn output(self, logger) {
  logger.write_string(
    "line \{self.line}, column \{self.column} (offset \{self.offset})",
  )
}

///|
/// A syntax error or an exceeded limit. Errors from the input source itself
/// (such as I/O errors or cancellation) are passed through unchanged.
#derive(Eq, Debug, ToJson)
pub(all) suberror ParseError {
  /// A character that cannot appear here.
  UnexpectedChar(Position, Char)
  /// The input ended inside a value, or before the first value.
  UnexpectedEof(Position)
  /// A `\u` escape of a surrogate that is not half of an escaped pair.
  /// The position is that of the backslash.
  UnpairedSurrogate(Position)
  /// A container opened at the position would exceed the depth limit.
  DepthLimitExceeded(Position, Int32)
  /// A string, property name or number starting at the position is longer
  /// than the length limit.
  TooLong(Position, Int32)
  /// An earlier call was interrupted, for example cancelled, while reading
  /// the input; the parser cannot continue.
  Interrupted
}

///|
pub impl Show for ParseError with fn output(self, logger) {
  let message = match self {
    UnexpectedChar(pos, c) =>
      "unexpected character \{c.to_string().escape()} at \{pos}"
    UnexpectedEof(pos) => "unexpected end of input at \{pos}"
    UnpairedSurrogate(pos) => "unpaired surrogate escape at \{pos}"
    DepthLimitExceeded(pos, limit) => "nesting deeper than \{limit} at \{pos}"
    TooLong(pos, limit) => "token longer than \{limit} code units at \{pos}"
    Interrupted => "an earlier call was interrupted while reading the input"
  }
  logger.write_string(message)
}

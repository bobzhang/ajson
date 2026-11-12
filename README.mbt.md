# bobzhang/ajson

An asynchronous streaming JSON parser for MoonBit, built on `lexscan` over
`@lexbuf.AsyncLexbuf`.

- Pull API: `next_event()` returns one event at a time; `next_value()`,
  `next_member()` and `skip_value()` work on whole values from any position.
- Memory proportional to nesting depth: an explicit container stack, no
  recursion, with a configurable depth limit.
- Input arrives in chunks from any async source; tokens may span chunk
  boundaries, including surrogate pairs and multi-byte UTF-8 sequences.
- Strict RFC 8259, with the same accept/reject decisions and values as
  `@json.parse`, which the tests check differentially.
- One document, or a stream of them (newline-delimited JSON, concatenated
  documents).
- Errors carry an offset, line and column.

Supported targets: native, js and wasm (those that core's async runtime
supports).

## Example

```mbt check
///|
async test "read an array of objects in chunks" {
  let parts = ["[{\"name\": \"a\", \"n\": 1}, {\"na", "me\": \"b\", \"n\": 2}]"]
  let mut i = 0
  let parser = @ajson.Parser::new(
    @lexbuf.AsyncLexbuf::from_fn(() => {
      if i < parts.length() {
        i += 1
        Some(parts[i - 1])
      } else {
        None
      }
    }),
  )
  guard parser.next_event() is Some(StartArray) else { fail("not an array") }
  let names = []
  while parser.next_value() is Some(Object(members)) {
    if members.get("name") is Some(String(name)) {
      names.push(name)
    }
  }
  debug_inspect(names, content="[\"a\", \"b\"]")
  assert_true(parser.next_event() is None)
}
```

Reading standard input (native, wasm):

```moonbit nocheck
let parser = @ajson.Parser::from_reader(@stdio.stdin.text, multiple_values=true)
parser.each_value(value => println(value.stringify()))
```

`cmd/example` is a complete program: `example count` counts the elements of a
top-level array without building them, and `example field NAME` prints a field
of each value of newline-delimited JSON.

```bash
moon build --target native --release
./_build/native/release/build/cmd/example/example.exe count < big.json
```

## API

```moonbit nocheck
Parser::new(lexbuf : @lexbuf.AsyncLexbuf, max_depth? : Int = 1024,
            max_string_length? : Int, multiple_values? : Bool = false) -> Parser
Parser::from_reader[R : @io.TextReader](reader : R, ...same options) -> Parser

async Parser::next_event(self) -> Event?         // None at the end of input
async Parser::next_value(self) -> Json?          // next complete value
async Parser::next_member(self) -> (String, Json)?
async Parser::skip_value(self) -> Bool
async Parser::each_value(self, f : async (Json) -> Unit) -> Unit
Parser::position(self) -> Position
Parser::depth(self) -> Int

enum Event { StartObject, EndObject, StartArray, EndArray, Key(String), Value(Json) }
struct Position { offset : Int, line : Int, column : Int }
suberror ParseError {
  UnexpectedChar(Position, Char), UnexpectedEof(Position),
  UnpairedSurrogate(Position), DepthLimitExceeded(Position, Int),
  TooLong(Position, Int), Interrupted
}
```

- `next_value()` at the top level returns the next document. Inside an array
  it returns the next element, and `None` when the array ends (the `EndArray`
  is consumed). Inside an object use `next_member()`, which returns `None` at
  the `EndObject`. `skip_value()` has the contract of `next_value()` but builds
  nothing.
- Values are the ones `@json.parse` gives: duplicate keys keep the last value,
  and numbers carry `repr` exactly when `@json.parse` would.
- `Position.offset` counts UTF-16 code units from the start of the stream;
  `line` is 1-based and `column` 0-based, as in `@json.Position`; `column`
  counts UTF-16 code units.
- After an error every later call raises it again; events scanned before the
  error are returned first. An error from the source (an I/O error, a
  cancellation) is kept the same way, so do not reuse the lexbuf afterwards.

### Options

- `max_depth`: the deepest nesting accepted (default 1024, as `@json.parse`).
- `max_string_length`: rejects strings, property names and number literals
  longer than this many UTF-16 code units. It also switches to a scanner that
  reads at most 64 characters per `lexscan` call, so memory stays bounded by
  about one input chunk even for huge tokens. That scanner is slower (see
  below). Without the option, a single token is buffered whole.
- `multiple_values`: the input is a sequence of values separated by optional
  whitespace. A top-level number, `true`, `false` or `null` must be followed by
  whitespace or the end of input, so `1 2` is two values but `1[2]` is an
  error. Empty input has no values.

## How it works

Each `lexscan` call scans a group of tokens: whitespace, punctuation, a
property name and a whole scalar value, such as `, "key": "value"` or `, 123`,
so an object member or an array element costs one async call. The string and
number regexes are those of core's lexscan JSON parser. A string is decoded
only if it contains a backslash; short integers are converted directly, other
numbers by `@json.parse`, so rounding and `repr` match exactly.

The regexes accept exactly the valid groups. When none matches, the parser
rescans the group token by token with a slow scanner that finds the precise
error position. The same slow scanner, whose pieces are bounded, does all the
work when `max_string_length` is set.

## Performance

`cmd/benchmark` parses a 2.3 MB document of records. `@json.parse` gets the
whole string; ajson reads it in 64 KiB chunks. Medians of 11 runs on Apple
Silicon, in milliseconds, with the released moonc v0.10.20 (2026-11-05) and
with a moonc built from compiler master (2026-11-12), which moves the async
refill out of the `lexscan` DFA loop:

| target | `@json.parse` | `next_value` | events only | `max_string_length` set |
| ------ | ------------- | ------------ | ----------- | ----------------------- |
| native, released | 17 | 193 | 174 | 523 |
| native, master   | 17 | 123 | 105 | 455 |
| js, released     | 28 | 283 | 246 | 535 |
| js, master       | 28 | 139 | 105 | 435 |
| wasm, released   | 43 | 530 | 500 | 1498 |
| wasm, master     | 43 | 334 | 311 | 1348 |

ajson is 5 to 10 times slower than parsing an in-memory string with
`@json.parse`. Profiles show the time spread over the generated async
`lexscan` code and allocation: async frames, and an event, a key and a value
per member. What it buys is reading input incrementally in memory
proportional to depth.

```bash
moon run --target native --release cmd/benchmark
```

## Tests

```bash
moon test --target native
moon test --target js
moon test --target wasm
```

The tests compare with `@json.parse` on valid and invalid documents
(JSONTestSuite-style cases), each fed whole, split in two at every character,
and split in two at every UTF-8 byte through `@io.MemoryReader` and
`@io.Utf8Reader`, with both scanners. An exhaustive check covers all 579,195
inputs of length 0 to 5 over 14 JSON characters. Other tests cover events,
error positions, depth limits, nesting 200,000 deep, multiple values, length
limits and source errors.

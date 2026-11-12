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
  `@json.parse`, which the tests check differentially. Input strings must be
  well-formed UTF-16, as MoonBit strings are; a lone surrogate code unit in
  the input is rejected.
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
- After a syntax error every later call raises it again, and the events
  before the error are returned first. An error raised by the source (an I/O
  error) is kept the same way, but the events of the token group being scanned
  when it happened may be lost: the fast scanner's lookahead fails before the
  group is committed. After a cancellation, later calls raise `Interrupted`.
  Either way, do not reuse the lexbuf afterwards.

### Options

- `max_depth`: the deepest nesting accepted (default 1024, as `@json.parse`).
- `max_string_length`: rejects strings, property names and number literals
  longer than this many UTF-16 code units. It also switches to a scanner that
  reads at most 64 characters per `lexscan` call, so the parser's memory is
  bounded by the depth, about one input chunk, and the token being decoded,
  which is at most `max_string_length`. That scanner is slower (see below).
  Without the option, a single token is buffered whole. Either way,
  `next_value()` builds the whole value it returns.
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
with a moonc built from compiler master (2026-11-12, 629b0fa), which moves the
async refill out of the `lexscan` DFA loop:

| target | `@json.parse` | `next_value` | events only | `max_string_length` set |
| ------ | ------------- | ------------ | ----------- | ----------------------- |
| native, released | 17 | 187 | 172 | 509 |
| native, master   | 17 | 119 | 105 | 445 |
| js, released     | 27 | 276 | 246 | 535 |
| js, master       | 28 | 129 | 106 | 429 |
| wasm, released   | 43 | 523 | 500 | 1494 |
| wasm, master     | 43 | 325 | 310 | 1337 |

```bash
moon run --target native --release cmd/benchmark
```

### Where the time goes: async compilation

Most of the gap is the cost of `async` itself, not of JSON. `cmd/asynctax`
runs the same capture-heavy `lexscan` (one object member, as in ajson's fast
scanner) 200,000 times over the three targets, the streaming ones fed 64 KiB
chunks (milliseconds):

| target | `StringScanner` | `Lexbuf` (sync) | `AsyncLexbuf`, released | `AsyncLexbuf`, master |
| ------ | --------------- | --------------- | ----------------------- | --------------------- |
| native | 9               | 18              | 141 (7.6x `Lexbuf`)     | 63 (3.5x)             |
| js     | 19              | 49              | 245 (4.8x)              | 83 (1.7x)             |
| wasm   | 16              | 43              | 400 (8.2x)              | 200 (4.7x)            |

```bash
moon run --target native --release cmd/asynctax
```

Only about one scan in tens of thousands reaches the end of the buffer and
suspends to refill; every other scan runs to completion synchronously. Yet the
generated code pays for suspension on every call. In the native output of
compiler master, each fast-scan call allocates 10 to 16 heap objects on entry
before reading a character (`scan_object_next`: 16, `scan_member`: 14,
`scan_array_next`: 12, `scan_value`: 10). They are the `MutLocal` boxes of the
DFA registers (state, accept state, match end, capture tags and tag savers),
boxed because they are live across the `__refill` suspension point, plus the
continuation closures of the CPS calling convention. Every async call on the
way, such as `next_event`, allocates its own continuations as well.

Other languages show the cost need not be there. A Rust `async fn` compiles to
a state machine inlined into its caller's future and allocates nothing unless
boxed; C# keeps an async method's state machine on the stack until its first
real suspension; OCaml 5 effects and Go goroutines capture a continuation or
stack only when they block. In all of these a call that does not suspend costs
close to a sync call, about 1.0 to 1.2 times for Rust, OCaml and Go. JS
`async` functions always go through a promise and a microtask, which is why
JS parsers keep their hot loops synchronous.

Suggestions for the compiler, in the order we expect to pay off:

1. **Box on suspension, not on entry.** Keep locals that are live across a
   suspension point as plain locals on the path that does not suspend. At a
   suspension that actually happens, spill all of them into one heap frame
   (one allocation, not one per local) and reload them on resumption. For
   `lexscan` over `AsyncLexbuf` the only suspension is the cold refill, so this
   removes the per-scan allocations.
2. **A synchronous fast path for async `lexscan`.** Generate the `Lexbuf` code
   for the buffered input first. If the DFA decides before reaching the end of
   the buffer, which is almost always, commit and run the case body as usual;
   otherwise restart the scan from its start with the current async code. No
   state crosses from one to the other, so the hot path is exactly the sync
   one, at the cost of code size.
3. **Direct return for async calls that complete synchronously.** Let an async
   call return its result directly, or a "suspended" marker, and allocate the
   continuation only when the callee really suspends, as C# does with
   `ValueTask` and Kotlin with its suspension marker. This helps every layer of
   async functions, not only `lexscan`: ajson makes two or three async calls
   per event.
4. **Inline small async wrappers** (functions that only forward to one async
   call) so that they do not add a frame and continuations of their own.

With 1 or 2, `AsyncLexbuf` should come within about 1.2 times of `Lexbuf`.
On native the async cost is about 225 ns per scan ((63 - 18) ms / 200,000),
and the benchmark document takes about 11 scans per record, 220,000 in all:
roughly 50 of ajson's 105 ms (events only). Removing it would bring ajson to
about 3 times `@json.parse` on an in-memory string; suggestions 3 and 4 cut
into the async calls around the scans. The rest is per-event allocation (an
event, a key and a value per member) that a pull parser cannot avoid.

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

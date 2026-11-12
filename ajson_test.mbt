///|
/// Documents that `@json.parse` accepts, one per line.
let valid_lines : String =
  #|[]
  #|{}
  #|  [ ]
  #|{ }
  #|0
  #|-0
  #|-0.0
  #|1
  #|-1
  #|123456789012345
  #|1234567890123456
  #|9007199254740991
  #|9007199254740993
  #|-123123123123123123123123123123
  #|1e400
  #|-1e400
  #|1.5
  #|1E22
  #|1e-7
  #|0e+1
  #|0.000001
  #|123.456e-789
  #|3.141592653589793238462643383279
  #|true
  #|false
  #|null
  #|""
  #|"a"
  #|" "
  #|"asd"
  #|"\"\\\/\b\f\n\r\t"
  #|"\u0000"
  #|"\u0060\u012a\u12AB"
  #|"\uD801\udc37"
  #|"\ud83d\ude00 smile"
  #|"€𝄞 é 中文"
  #|"😀"
  #|"a\u00e9b\u20acc\ud834\udd1ed"
  #|[""]
  #|[1,2,3]
  #|[1, 2 ,3 ]
  #|[[[]]]
  #|[[], {}, [[]], {"a": {}}]
  #|{"":0}
  #|{"a":"b"}
  #|{"a":1,"b":2}
  #|{"a":"b","a":"c"}
  #|{"b":1,"a":2,"b":3}
  #|{ "a" : [ 1 , { "b" : null } ] , "c" : true }
  #|{"\u00e9":"\ud83d\ude00"}
  #|{"key with \"escapes\"\n":"v"}
  #|[true,false,null]
  #|[-0,0,-1.5e3,2E-2]
  #|{"a":[1,[2,[3,{"b":[]}]]]}
  #|[{"a":{}},{"b":[]}]
  #|["a","b",{"c":"d"}]
  #|	[1]
  #|"\/"

///|
/// Documents that `@json.parse` rejects, one per line.
let invalid_lines : String =
  #|[1,]
  #|[,1]
  #|[,]
  #|{"a":1,}
  #|{,}
  #|{"a"}
  #|{"a":}
  #|{"a" 1}
  #|{1:1}
  #|{'a':1}
  #|{a:1}
  #|["a"
  #|[1 2]
  #|[1 true]
  #|{"a":1 "b":2}
  #|[01]
  #|[00]
  #|[-01]
  #|[1.]
  #|[.1]
  #|[-]
  #|[+1]
  #|[1e]
  #|[1e+]
  #|[1.e1]
  #|[1.5.3]
  #|[0x10]
  #|[NaN]
  #|[Infinity]
  #|[-Infinity]
  #|[tru]
  #|[True]
  #|[nul]
  #|[fals]
  #|[truee]
  #|["\x"]
  #|["\u12"]
  #|["\u12G4"]
  #|["\uD800"]
  #|["\uDC00"]
  #|["\uD800\u0041"]
  #|["\uD800\uD800"]
  #|["\uD800\"]
  #|["\uD800x"]
  #|["\'"]
  #|["a	b"]
  #|["\"]
  #|[
  #|]
  #|{
  #|}
  #|
  #|
  #|[]x
  #|[] []
  #|{}}
  #|[1]]
  #|"
  #|"abc
  #|[1,2
  #|{"a":1
  #|{"a"
  #|{"a":
  #|[1,{]
  #|1 2
  #|"a""b"
  #|-
  #|--1
  #|1-
  #|[ 1]x
  #|nulll
  #|[null,]
  #|{"a":1}{"b":2}
  #|[1]  ,
  #|[ ][

///|
fn lines(s : String) -> Array[String] {
  s.split("\n").map(l => l.to_owned()).to_array()
}

///|
async test "valid documents agree with @json.parse in every split" {
  for doc in lines(valid_lines) {
    let ok = Ok(@json.parse(doc)) catch { e => Err(e) }
    guard ok is Ok(_) else { fail("expected valid: \{doc.escape()}") }
    check_all_splits(doc)
  }
  // Documents with line breaks.
  check_all_splits("[\n  1,\n  {\"a\": [true,\r\n false]}\n]\n")
  check_all_splits("\n\n{\n\"k\"\n:\n\"v\"\n}\n\n")
}

///|
async test "invalid documents agree with @json.parse in every split" {
  for doc in lines(invalid_lines) {
    let ok = Ok(@json.parse(doc)) catch { e => Err(e) }
    guard ok is Err(_) else { fail("expected invalid: \{doc.escape()}") }
    check_all_splits(doc)
  }
  // Raw control characters and a non-ASCII space.
  check_all_splits("[\"a\nb\"]")
  check_all_splits("[\"\u{1}\"]")
  check_all_splits("[\u{A0}1]")
  check_all_splits("[1\u{0}]")
}

///|
async test "a larger document agrees with @json.parse in every split" {
  let doc =
    #|{"id": 12345, "name": "caf\u00e9 \ud83d\ude00", "tags": ["a", "b\n", ""],
    #| "nested": {"deep": [[1, 2.5e-3, -0], {"x": null, "y": true}], "z": false},
    #| "big": 123456789012345678901234567890, "neg": -9007199254740993,
    #| "text": "Grüße, 世界! 😀 \"quoted\" \\ back"}
  check_all_splits(doc)
}

///|
/// Every input of length 0 to 5 over a small alphabet: accept or reject and
/// the values agree with `@json.parse`, in both scanning modes.
async test "exhaustive small inputs" {
  let alphabet = [
    '[', ']', '{', '}', ',', ':', '"', '0', '1', '-', '.', 'e', '\\', ' ',
  ]
  let n = alphabet.length()
  let mut count = 0
  let mut valid = 0
  for len in 0..<=5 {
    let mut total = 1
    for _ in 0..<len {
      total *= n
    }
    for code in 0..<total {
      let sb = StringBuilder()
      let mut c = code
      for _ in 0..<len {
        sb.write_char(alphabet[c % n])
        c /= n
      }
      let input = sb.to_string()
      let expected = Ok(@json.parse(input)) catch { e => Err(e) }
      if expected is Ok(_) {
        valid += 1
      }
      agree(input, parse_parts([input]), "whole")
      agree(input, parse_parts([input], max_string_length=1 << 30), "limited")
      count += 1
    }
  }
  inspect(count, content="579195")
  inspect(valid, content="2869")
}

///|
async test "events" {
  let input = "{\"a\": [1, \"x\", {}], \"b\": {\"c\": null}, \"d\": []}"
  debug_inspect(
    events(input),
    content=(
      #|Ok(
      #|  [
      #|    StartObject,
      #|    Key("a"),
      #|    StartArray,
      #|    Value(Number(1)),
      #|    Value(String("x")),
      #|    StartObject,
      #|    EndObject,
      #|    EndArray,
      #|    Key("b"),
      #|    StartObject,
      #|    Key("c"),
      #|    Value(Null),
      #|    EndObject,
      #|    Key("d"),
      #|    StartArray,
      #|    EndArray,
      #|    EndObject,
      #|  ],
      #|)
    ),
  )
  // The slow scanner produces the same events.
  guard events(input, max_string_length=100) is Ok(slow) &&
    events(input) is Ok(fast) else {
    fail("rejected")
  }
  assert_eq(slow, fast)
}

///|
/// `events` in both scanning modes, which must agree.
async fn events_both(input : String) -> Result[Array[@ajson.Event], Error] {
  let fast = events(input)
  let slow = events(input, max_string_length=100)
  assert_true(same_result(fast, slow))
  fast
}

///|
async test "error positions" {
  debug_inspect(
    events_both("[1, 2,\n  tru]"),
    content=(
      #|Err(UnexpectedChar({ offset: 12, line: 2, column: 5 }, ']'))
    ),
  )
  debug_inspect(
    events_both("{\"a\": 1,\n \"b\" 2}"),
    content=(
      #|Err(UnexpectedChar({ offset: 14, line: 2, column: 5 }, '2'))
    ),
  )
  debug_inspect(
    events_both("[\"ab\\x\"]"),
    content=(
      #|Err(UnexpectedChar({ offset: 5, line: 1, column: 5 }, 'x'))
    ),
  )
  debug_inspect(
    events_both("[\"ab\\ud800\"]"),
    content=(
      #|Err(UnpairedSurrogate({ offset: 4, line: 1, column: 4 }))
    ),
  )
  debug_inspect(
    events_both("[\n1,\n\"\\udc00\"]"),
    content=(
      #|Err(UnpairedSurrogate({ offset: 6, line: 3, column: 1 }))
    ),
  )
  debug_inspect(
    events_both("[1, 2"),
    content=(
      #|Err(UnexpectedEof({ offset: 5, line: 1, column: 5 }))
    ),
  )
  debug_inspect(
    events_both(""),
    content=(
      #|Err(UnexpectedEof({ offset: 0, line: 1, column: 0 }))
    ),
  )
  debug_inspect(
    events_both("{} x"),
    content=(
      #|Err(UnexpectedChar({ offset: 3, line: 1, column: 3 }, 'x'))
    ),
  )
  debug_inspect(
    events_both("[1.]"),
    content=(
      #|Err(UnexpectedChar({ offset: 2, line: 1, column: 2 }, '.'))
    ),
  )
  debug_inspect(
    events_both("[\"😀\", x]"),
    content=(
      #|Err(UnexpectedChar({ offset: 7, line: 1, column: 7 }, 'x'))
    ),
  )
}

///|
async test "events before an error are returned first" {
  let p = @ajson.Parser::new(
    @lexbuf.AsyncLexbuf::from_fn(chunks(["{\"a\": tru}"])),
  )
  debug_inspect(p.next_event(), content="Some(StartObject)")
  debug_inspect(p.next_event(), content="Some(Key(\"a\"))")
  let e1 = try p.next_event() catch {
    e => e.to_string()
  } noraise {
    _ => "ok"
  }
  let e2 = try p.next_event() catch {
    e => e.to_string()
  } noraise {
    _ => "ok"
  }
  inspect(
    e1,
    content=(
      #|unexpected character "}" at line 1, column 9 (offset 9)
    ),
  )
  assert_eq(e1, e2)
}

///|
async test "depth limit" {
  let ok = "[".repeat(1024) + "]".repeat(1024)
  let bad = "[".repeat(1025) + "]".repeat(1025)
  agree(ok, parse_parts([ok]), "1024 deep")
  agree(bad, parse_parts([bad]), "1025 deep")
  agree(ok, parse_parts([ok], max_string_length=10), "1024 deep limited")
  agree(bad, parse_parts([bad], max_string_length=10), "1025 deep limited")
  let objects = "{\"a\":".repeat(1024) + "1" + "}".repeat(1024)
  agree(objects, parse_parts([objects]), "1024 deep objects")
  debug_inspect(
    parse_parts(["[[{}]]"], max_depth=2),
    content=(
      #|Err(DepthLimitExceeded({ offset: 2, line: 1, column: 2 }, 2))
    ),
  )
  debug_inspect(
    parse_parts(["[[[]]]"], max_depth=2),
    content=(
      #|Err(DepthLimitExceeded({ offset: 2, line: 1, column: 2 }, 2))
    ),
  )
  debug_inspect(parse_parts(["1"], max_depth=0), content="Ok(Number(1))")
}

///|
async test "deep nesting does not use the call stack" {
  let depth = 200000
  let doc = "[".repeat(depth) + "]".repeat(depth)
  let parts = []
  for i = 0; i < doc.length(); i = i + 4096 {
    let end = @cmp.minimum(i + 4096, doc.length())
    parts.push(doc.exact_view(start=i, end~).to_owned())
  }
  guard parse_parts(parts, max_depth=depth) is Ok(v) else { fail("rejected") }
  let mut d = 1
  let mut cur = v
  while cur is Array([inner]) {
    d += 1
    cur = inner
  }
  assert_eq(d, depth)
}

///|
async fn values(
  input : String,
  max_string_length? : Int32,
) -> Result[Array[Json], Error] {
  let p = @ajson.Parser::new(
    @lexbuf.AsyncLexbuf::from_fn(chunks([input])),
    multiple_values=true,
    max_string_length?,
  )
  let out = []
  try {
    p.each_value(v => out.push(v))
    Ok(out)
  } catch {
    e => Err(e)
  }
}

///|
/// `values` in both scanning modes, which must agree.
async fn values_both(input : String) -> Result[Array[Json], Error] {
  let fast = values(input)
  let slow = values(input, max_string_length=100)
  assert_true(same_result(fast, slow))
  fast
}

///|
async test "multiple values" {
  debug_inspect(
    values_both("{\"a\":1}\n{\"a\":2}\n[3]\n\"x\"\n4\ntrue\n"),
    content=(
      #|Ok(
      #|  [
      #|    Object({ "a": Number(1) }),
      #|    Object({ "a": Number(2) }),
      #|    Array([Number(3)]),
      #|    String("x"),
      #|    Number(4),
      #|    True,
      #|  ],
      #|)
    ),
  )
  debug_inspect(values_both(""), content="Ok([])")
  debug_inspect(values_both(" \n\t "), content="Ok([])")
  debug_inspect(
    values_both("[1][2]{}\"a\"\"b\""),
    content=(
      #|Ok(
      #|  [
      #|    Array([Number(1)]),
      #|    Array([Number(2)]),
      #|    Object({}),
      #|    String("a"),
      #|    String("b"),
      #|  ],
      #|)
    ),
  )
  debug_inspect(
    values_both("1 2 12"),
    content="Ok([Number(1), Number(2), Number(12)])",
  )
  debug_inspect(
    values_both("1[2]"),
    content=(
      #|Err(UnexpectedChar({ offset: 1, line: 1, column: 1 }, '['))
    ),
  )
  debug_inspect(
    values_both("true\"a\""),
    content=(
      #|Err(UnexpectedChar({ offset: 4, line: 1, column: 4 }, '"'))
    ),
  )
  debug_inspect(
    values_both("{}\n{]\n"),
    content=(
      #|Err(UnexpectedChar({ offset: 4, line: 2, column: 1 }, ']'))
    ),
  )
}

///|
async test "multiple values split at every boundary" {
  let input = "{\"a\": [1, 2]}\n\"s\\n\" 3.5 null\n[{\"b\": \"😀\"}]\r\n"
  let expected : Array[Json] = [
    { "a": [1, 2] },
    "s\n",
    3.5,
    null,
    [{ "b": "😀" }],
  ]
  let boundaries = [0]
  for c in input {
    boundaries.push(boundaries[boundaries.length() - 1] + c.utf16_len())
  }
  for i in boundaries {
    let left = input.exact_view(end=i).to_owned()
    let right = input.exact_view(start=i).to_owned()
    for limit in [None, Some(1000)] {
      let p = @ajson.Parser::new(
        @lexbuf.AsyncLexbuf::from_fn(chunks([left, right])),
        multiple_values=true,
        max_string_length?=limit,
      )
      let got = []
      p.each_value(v => got.push(v))
      assert_true(
        got.length() == expected.length() &&
        got.iter().zip(expected.iter()).all(p => strict_eq(p.0, p.1)),
      )
    }
  }
}

///|
async test "string length limit" {
  debug_inspect(
    parse_parts(["[\"abcd\"]"], max_string_length=4),
    content=(
      #|Ok(Array([String("abcd")]))
    ),
  )
  debug_inspect(
    parse_parts(["[\"abcde\"]"], max_string_length=4),
    content=(
      #|Err(TooLong({ offset: 1, line: 1, column: 1 }, 4))
    ),
  )
  debug_inspect(
    parse_parts(["{\"abcde\": 1}"], max_string_length=4),
    content=(
      #|Err(TooLong({ offset: 1, line: 1, column: 1 }, 4))
    ),
  )
  // Escapes count as the characters they decode to.
  debug_inspect(
    parse_parts(["\"\\u00e9\\n\\ud83d\\ude00\""], max_string_length=4),
    content=(
      #|Ok(String("é\n😀"))
    ),
  )
  debug_inspect(
    parse_parts(["[12345]"], max_string_length=4),
    content=(
      #|Err(TooLong({ offset: 1, line: 1, column: 1 }, 4))
    ),
  )
  debug_inspect(
    parse_parts(["[-1.5e+3]"], max_string_length=7),
    content="Ok(Array([Number(-1500)]))",
  )
  // A long string within the limit, delivered in small chunks.
  let s = "x".repeat(1000) + "é😀" + "y".repeat(1000)
  let doc = "[\"" + s + "\"]"
  let parts = []
  let mut i = 0
  while i < doc.length() {
    let mut end = @cmp.minimum(i + 7, doc.length())
    // Keep surrogate pairs together.
    if end < doc.length() && doc.at(end) is (0xDC00..<=0xDFFF) {
      end += 1
    }
    parts.push(doc.exact_view(start=i, end~).to_owned())
    i = end
  }
  guard parse_parts(parts, max_string_length=s.length())
    is Ok(Array([String(t)])) else {
    fail("rejected")
  }
  assert_eq(t, s)
  guard parse_parts(parts, max_string_length=s.length() - 1) is Err(_) else {
    fail("accepted")
  }
}

///|
async test "next_member and next_value inside containers" {
  let p = @ajson.Parser::new(
    @lexbuf.AsyncLexbuf::from_fn(
      chunks(["{\"items\": [1, {\"x\": 2}, [3]], \"name\": \"n\"}"]),
    ),
  )
  debug_inspect(p.next_event(), content="Some(StartObject)")
  debug_inspect(p.next_event(), content="Some(Key(\"items\"))")
  debug_inspect(p.next_event(), content="Some(StartArray)")
  assert_eq(p.depth(), 2)
  let items = []
  while p.next_value() is Some(v) {
    items.push(v)
  }
  debug_inspect(
    items,
    content=(
      #|[Number(1), Object({ "x": Number(2) }), Array([Number(3)])]
    ),
  )
  debug_inspect(
    p.next_member(),
    content=(
      #|Some(("name", String("n")))
    ),
  )
  debug_inspect(p.next_member(), content="None")
  debug_inspect(p.next_value(), content="None")
  debug_inspect(p.next_event(), content="None")
  debug_inspect(p.position(), content="{ offset: 42, line: 1, column: 42 }")
}

///|
suberror SourceFailed

///|
async test "errors from the source are kept" {
  let mut calls = 0
  let p = @ajson.Parser::new(
    @lexbuf.AsyncLexbuf::from_fn(() => {
      calls += 1
      if calls == 1 {
        Some("[1, 2")
      } else {
        raise SourceFailed
      }
    }),
  )
  debug_inspect(p.next_event(), content="Some(StartArray)")
  debug_inspect(p.next_event(), content="Some(Value(Number(1)))")
  let r1 = Ok(p.next_event()) catch { e => Err(e) }
  let r2 = Ok(p.next_event()) catch { e => Err(e) }
  assert_true(r1 is Err(SourceFailed))
  assert_true(r2 is Err(SourceFailed))
  assert_eq(calls, 2)
}

// Learn more about moon.mod configuration:
// https://docs.moonbitlang.com/en/latest/toolchain/moon/module.html
//
// To add a dependency, run this command in your terminal:
//   moon add moonbitlang/x
//
// Or manually declare it in `import`, for example:
// import {
//   "moonbitlang/x@0.4.6",
// }

name = "bobzhang/ajson"

version = "0.1.0"

readme = "README.mbt.md"

repository = "https://github.com/bobzhang/ajson"

license = "Apache-2.0"

keywords = [ "json", "streaming", "async", "parser", "lexscan" ]

preferred_target = "wasm"

description = "Asynchronous streaming JSON pull parser built on lexscan"

warnings = "-implicit_impl_as_method-result_error_return"

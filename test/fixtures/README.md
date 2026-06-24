# Test fixtures

`mruby-wasm-js.wasm` — a representative mruby-wasm-js build with the compiler
(`js_eval_handle`), used by the VM integration tests. It is lilac's
`lilac-full.release` artifact, but the tests exercise only mruby + the
mruby-wasm-js `JS` bridge (`JS.global` / `JS.callback` / `Promise#await`), not
Lilac's component API — it's just a convenient real-world host binary.

Override with the `DOMMY_JS_WASMTIME_TEST_WASM` env var to test against a
different mruby-wasm-js build.

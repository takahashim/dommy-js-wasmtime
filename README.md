# dommy-js-wasmtime

[![CI](https://github.com/takahashim/dommy-js-wasmtime/actions/workflows/ci.yml/badge.svg)](https://github.com/takahashim/dommy-js-wasmtime/actions/workflows/ci.yml)

Run an **mruby-wasm-js** build on
[wasmtime-rb](https://github.com/bytecodealliance/wasmtime-rb), bridged to a
[Dommy](https://github.com/takahashim/dommy) DOM — no browser, no Node, no
happy-dom. The [Lilac](https://github.com/takahashim/lilac) component runtime is
the primary example, but the gem itself doesn't depend on Lilac: it targets the
generic mruby-wasm-js host ABI.

It is the wasmtime sibling of `dommy-js-quickjs`. Where `dommy-js-quickjs` runs
*JavaScript* against Dommy, this gem runs *mruby* (inside wasm, on wasmtime) and
serves its JS interop from a real JS world:

```
  mruby (app.wasm)  ──js.* handle ABI──▶  VM (wasmtime host)
                                            │
                                            ▼  Engines::Quickjs
                                     QuickJS globalThis  ──dommy-js-quickjs──▶  Dommy DOM
```

So `JS.global` is a real `globalThis`, promises / `await` / `fetch` work, and the
same DOM the wasm mutates is inspectable from Ruby via Dommy's API.

## How it works

The wasm imports two modules; this gem implements both in pure Ruby:

- **`js`** — the 25-function handle-table interop ABI (`js_global`, `js_get`,
  `js_call`, `js_new`, `js_make_callback`, …). Values cross as small integer
  handles; the VM stores the Ruby/JS objects and routes property/method access
  through the bridge ABI (`__js_get__` / `__js_set__` / `__js_call__` /
  `__js_new__`). The default engine (`Engines::Quickjs`) backs each handle with a
  live QuickJS value (`JsRef`).
- **`wasi_snapshot_preview1`** — wasmtime's bundled WASI preview1, with `fd_write`
  shadowed to capture mruby stdout/stderr.

mruby-wasm-js builds use the WebAssembly exception-handling proposal (mruby's
longjmp); wasmtime enables it via `Engine.new(wasm_exceptions: true)`.

## Usage

```ruby
require "dommy"
require "dommy/js/wasmtime"

vm = Dommy::Js::Wasmtime.boot(
  wasm: "build/app.wasm",
  html: File.read("index.html"),
  sources: Dir["lib/*.rb"],          # mruby source files, loaded in order
  entrypoint: "Lilac.start",         # app boot call after sources load (or nil)
) do |engine|
  engine.eval(<<~JS)                 # seed the JS world (e.g. a fetch fixture)
    globalThis.fetch = async (u) => new Response(DATA_JSON, { status: 200 });
  JS
end

vm.document.query_selector(".app")   # the DOM the mruby app rendered
```

`boot` builds the VM, runs `_initialize`, optionally seeds the JS world, loads the
mruby sources, and evals `entrypoint` (e.g. `Lilac.start` to mount components).
After each `eval`, the event loop is driven to quiescence so fibers suspended on
`.await` settle.

For lower-level use, drive the VM directly — it has no app-framework knowledge:

```ruby
vm = Dommy::Js::Wasmtime::VM.new(wasm: "build/app.wasm")
vm.eval('JS.global[:document].call(:querySelector, "h1")')
vm.stdout
```

## Development

```bash
bundle install
bundle exec rake        # runs the test suite + RuboCop
bundle exec rake test
```

The suite has two layers: engine unit tests (`Engines::Quickjs`, no wasm —
marshalling, the JsRef bridge ABI, callbacks, the event-loop drive) and VM
integration tests that run real mruby through the `js.*` bridge against
QuickJS+Dommy (DOM read/write, callback round-trips, `await`, JS-error capture).

The integration tests need an mruby-wasm-js `.wasm` with the compiler
(`js_eval_handle`). A representative build (lilac-full) is vendored at
`test/fixtures/mruby-wasm-js.wasm`; point `DOMMY_JS_WASMTIME_TEST_WASM` at another
build to override. The tests use only mruby + the `JS` module, not Lilac's
component API.

## Status

Extracted from lilac's reference host (`test/ruby_spec/mruby_wasm.rb` +
`quickjs_bridge.rb`); additionally cross-checked by running lilac's own wasm spec
suite through this VM and diffing per-spec results against the reference host
(identical).

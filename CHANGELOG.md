# Changelog

## [Unreleased]

- Initial release.
- `Dommy::Js::Wasmtime::VM` — a wasmtime-rb host for mruby-wasm-js builds (the
  Lilac runtime): implements the 25-function `js.*` handle-table interop ABI and
  the WASI preview1 surface, routing JS interop to a pluggable engine.
- `Dommy::Js::Wasmtime::Engines::Quickjs` — default engine; a QuickJS VM bound to
  a Dommy DOM (via `dommy-js-quickjs`), giving the wasm a real JS world
  (promises/await/fetch, full marshalling).
- `Dommy::Js::Wasmtime.boot` — convenience loader: build the VM over a Dommy DOM,
  seed the JS world, load mruby sources, and eval an `entrypoint` (e.g.
  `Lilac.start`).
- Minitest suite: engine unit tests + VM integration tests (against a vendored
  mruby-wasm-js fixture), plus a cross-check against lilac's own wasm spec suite.

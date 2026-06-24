# frozen_string_literal: true

require "minitest/autorun"
require "dommy"
require "dommy/js/wasmtime"

module TestSupport
  # An mruby-wasm-js build with the compiler (js_eval_handle). The vendored
  # fixture is lilac-full; the host tests below exercise only mruby + the `js.*`
  # bridge, not Lilac's component API. Override with DOMMY_JS_WASMTIME_TEST_WASM.
  FIXTURE_WASM = ENV.fetch("DOMMY_JS_WASMTIME_TEST_WASM") do
    File.expand_path("fixtures/mruby-wasm-js.wasm", __dir__)
  end

  # A VM over a Dommy DOM parsed from `html`. The block (optional) seeds the JS
  # world before sources load. No entrypoint is run.
  def build_vm(html: "<main></main>", sources: [], &)
    Dommy::Js::Wasmtime.boot(wasm: FIXTURE_WASM, html: html, sources: sources, &)
  end
end

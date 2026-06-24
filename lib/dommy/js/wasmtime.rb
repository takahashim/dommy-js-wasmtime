# frozen_string_literal: true

require "dommy"

require_relative "wasmtime/version"
require_relative "wasmtime/vm"

module Dommy
  module Js
    # A wasmtime-rb host for mruby-wasm-js builds, bridged to a Dommy DOM. The
    # wasmtime sibling of dommy-js-quickjs: it runs *mruby* (inside wasm on
    # wasmtime) and serves its `js.*` interop from a real JS world — a QuickJS VM
    # bound to Dommy (dommy-js-quickjs) — so `JS.global` is real globalThis,
    # promises/await/fetch work, and the same DOM the wasm mutates is inspectable
    # from Ruby. Any mruby-wasm-js build works; the Lilac component runtime is the
    # primary example.
    #
    #   require "dommy"
    #   require "dommy/js/wasmtime"
    #
    #   vm = Dommy::Js::Wasmtime.boot(
    #     wasm: "build/app.wasm",
    #     html: File.read("index.html"),
    #     sources: %w[lib/foo.rb lib/bar.rb …],       # mruby source files
    #     entrypoint: "Lilac.start",                  # app boot call (or nil)
    #   ) do |engine|
    #     engine.eval(<<~JS)                          # seed the JS world
    #       globalThis.fetch = async (u) => new Response(DATA_JSON, {…});
    #     JS
    #   end
    #   vm.document.query_selector(".app")            # driven by the mruby app
    module Wasmtime
      class Error < StandardError; end

      # Build a VM over a Dommy DOM, optionally seed the JS world (fetch stub,
      # globals), load the mruby source files, and run an app boot call — the Ruby
      # equivalent of a browser bootstrap script.
      #
      # @param wasm       [String] path to the mruby-wasm-js .wasm
      # @param html       [String, nil] HTML to parse into the window's document
      # @param window     [Dommy::Window, nil] explicit window (overrides html)
      # @param sources    [Array<String>] mruby source file paths (loaded in order)
      # @param entrypoint [String, nil] mruby expression to eval after sources
      #   load (e.g. "Lilac.start" to mount components); nil to skip
      # @yield [engine] optional hook to seed the JS world before sources load
      # @return [VM]
      def self.boot(wasm:, html: nil, window: nil, sources: [], entrypoint: nil)
        require_relative "wasmtime/engines/quickjs"
        win = window || Dommy.parse(html.to_s)
        vm = nil
        engine = Engines::Quickjs.new(invoke: ->(id, args) { vm.invoke_callback(id, args) }, window: win)
        vm = VM.new(wasm: wasm, engine: engine)
        yield engine if block_given?
        Array(sources).each { |path| vm.eval!(::File.read(path.to_s)) }
        vm.eval!(entrypoint) if entrypoint
        vm
      end
    end
  end
end

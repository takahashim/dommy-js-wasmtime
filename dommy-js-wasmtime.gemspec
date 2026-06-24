# frozen_string_literal: true

require_relative "lib/dommy/js/wasmtime/version"

Gem::Specification.new do |spec|
  spec.name = "dommy-js-wasmtime"
  spec.version = Dommy::Js::Wasmtime::VERSION
  spec.authors = ["TAKAHASHI Masayoshi"]
  spec.email = ["takahashimm@gmail.com"]

  spec.summary = "Run mruby-wasm-js builds on wasmtime-rb, bridged to a Dommy DOM"
  spec.description = "A wasmtime-rb host for mruby-wasm-js builds (the Lilac component runtime is the " \
                     "primary example). It reimplements the mruby-wasm-js `js.*` handle-table ABI and " \
                     "the WASI preview1 surface in pure Ruby, routing JS interop into Dommy's " \
                     "`__js_get__/__js_set__/__js_call__/__js_new__` bridge protocol. The wasmtime " \
                     "sibling of dommy-js-quickjs — but instead of running JavaScript it drives Dommy " \
                     "from mruby running inside wasm."
  spec.homepage = "https://github.com/takahashim/dommy-js-wasmtime"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2.0"

  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"

  spec.files = Dir["lib/**/*.rb", "README.md", "CHANGELOG.md", "LICENSE.txt"]
  spec.require_paths = ["lib"]

  spec.add_dependency "dommy", "~> 0.9"
  spec.add_dependency "dommy-js-quickjs", "~> 0.9"
  spec.add_dependency "wasmtime", ">= 45.0.0"
  spec.metadata['rubygems_mfa_required'] = 'true'
end

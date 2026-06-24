# frozen_string_literal: true

require "bundler/gem_tasks"
require "rake/testtask"
require "rubocop/rake_task"

Rake::TestTask.new(:test) do |t|
  t.libs << "test"
  t.libs << "lib"
  t.test_files = FileList["test/**/*_test.rb"]
end

RuboCop::RakeTask.new

# Tests need an mruby-wasm-js .wasm with the compiler (js_eval_handle). A
# representative build (lilac-full) is vendored at test/fixtures/; override with
# DOMMY_JS_WASMTIME_TEST_WASM. Correctness is also cross-checked against lilac's
# own wasm spec suite (the VM run through lilac's PURE_SPECS, diffed vs the
# reference host).
task default: %i[test rubocop]

# frozen_string_literal: true

require_relative "test_helper"
require "tempfile"

# The `boot` convenience loader: build a VM over a Dommy DOM, seed the JS world,
# load mruby sources in order, then eval an entrypoint. No Lilac dependency — the
# entrypoint is just an mruby expression.
class BootTest < Minitest::Test
  include TestSupport

  def test_seed_block_runs_before_and_entrypoint_after_sources
    src = Tempfile.new(["boot_src", ".rb"])
    src.write(<<~RUBY)
      def fill_title
        msg = JS.global[:SEED_MSG].to_s
        JS.global[:document].call(:querySelector, "#x")[:textContent] = msg
      end
    RUBY
    src.close

    vm = build_vm(html: "<main><p id='x'></p></main>", sources: [src.path]) do |engine|
      engine.eval("globalThis.SEED_MSG = 'seeded';") # seed runs before sources load
    end
    # `fill_title` is defined by the loaded source; call it as the entrypoint.
    vm.eval!("fill_title")

    assert_equal "seeded", vm.document.query_selector("#x").text_content
  ensure
    src&.unlink
  end

  def test_boot_without_entrypoint_just_builds_the_vm
    vm = build_vm(html: "<main><h1 id='t'>Hi</h1></main>")
    assert_kind_of Dommy::Js::Wasmtime::VM, vm
    assert_equal "Hi", vm.document.query_selector("#t").text_content
  end
end

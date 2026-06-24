# frozen_string_literal: true

require_relative "test_helper"

# The wasmtime host, end to end: mruby running inside the wasm reaches the DOM
# through the `js.*` bridge into QuickJS+Dommy, and Ruby drives it. These tests
# use only mruby + the mruby-wasm-js `JS` module (JS.global / JS.callback /
# Promise#await) — no Lilac component API — so they cover the host itself.
class VmTest < Minitest::Test
  include TestSupport

  def test_eval_runs_mruby_and_captures_stdout
    vm = build_vm
    rc = vm.eval('puts "hello from mruby"; puts(40 + 2)')
    assert_equal 0, rc
    out = vm.stdout
    assert_includes out, "hello from mruby"
    assert_includes out, "42"
  end

  def test_eval_bang_raises_on_mruby_error
    vm = build_vm
    err = assert_raises(Dommy::Js::Wasmtime::RubyError) { vm.eval!("raise 'boom'") }
    assert_match(/rc=/, err.message)
  end

  def test_mruby_reads_the_dom_through_the_bridge
    vm = build_vm(html: "<main><h1 id='t'>Hi</h1></main>")
    vm.eval('puts JS.global[:document].call(:querySelector, "#t")[:textContent]')
    assert_includes vm.stdout, "Hi"
  end

  def test_mruby_writes_to_the_dom_visible_from_ruby
    vm = build_vm(html: "<main><h1 id='t'>Hi</h1></main>")
    vm.eval('JS.global[:document].call(:querySelector, "#t")[:textContent] = "Bye"')
    assert_equal "Bye", vm.document.query_selector("#t").text_content
  end

  def test_callback_round_trip_on_a_dom_event
    vm = build_vm(html: "<main><button id='go'>go</button><span id='n'>0</span></main>")
    vm.eval(<<~RUBY)
      doc = JS.global[:document]
      n = doc.call(:querySelector, "#n")
      clicks = 0
      doc.call(:querySelector, "#go").call(:addEventListener, "click", JS.callback { |_e|
        clicks += 1
        n[:textContent] = clicks.to_s
      })
    RUBY
    # Fire the event from the Ruby/Dommy side; it must reach the mruby handler.
    vm.engine.eval('document.querySelector("#go").dispatchEvent(new MouseEvent("click", { bubbles: true }))')
    vm.drain_async!
    assert_equal "1", vm.document.query_selector("#n").text_content
  end

  def test_await_resolves_a_js_promise
    vm = build_vm
    vm.engine.eval("globalThis.answer = Promise.resolve(7);")
    vm.eval('puts JS.global[:answer].await')
    assert_includes vm.stdout, "7"
  end

  def test_js_error_surfaces_to_mruby_as_js_error
    # Regression guard for the @pending_error mechanism: a JS-side throw must
    # come back as a rescuable mruby JS::Error, not crash the host.
    vm = build_vm
    vm.eval(<<~RUBY)
      begin
        JS.global.call(:definitelyNotAFunction)
        puts "NO-ERROR"
      rescue => e
        puts "caught:" + e.class.to_s
      end
    RUBY
    out = vm.stdout
    refute_includes out, "NO-ERROR"
    assert_includes out, "caught:"
  end

  def test_stdout_and_stderr_are_separate
    vm = build_vm
    vm.eval('puts "to-out"; STDERR.puts "to-err"')
    assert_includes vm.stdout, "to-out"
    assert_includes vm.stderr, "to-err"
  end
end

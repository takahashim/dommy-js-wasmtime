# frozen_string_literal: true

require_relative "test_helper"
require "dommy/js/wasmtime/engines/quickjs"

# The default engine, exercised standalone (no wasm) — it only needs
# dommy-js-quickjs. Covers the value marshalling, the JsRef bridge ABI, the
# callback round-trip, and the event loop drive that the VM relies on.
class QuickjsEngineTest < Minitest::Test
  include TestSupport

  def setup
    @invoked = []
    @engine = Dommy::Js::Wasmtime::Engines::Quickjs.new(
      invoke: lambda { |id, args|
        @invoked << [id, args]
        "ret:#{id}"
      },
      window: Dommy.parse("<main><h1 id='t' class='hd'>Hi</h1></main>")
    )
  end

  def test_eval_marshals_primitives
    assert_equal 3, @engine.eval("1 + 2")
    assert_equal "hi", @engine.eval("'hi'")
    assert_equal true, @engine.eval("1 < 2")
    assert_nil @engine.eval("null")
    assert_nil @engine.eval("undefined")
  end

  def test_eval_object_is_a_jsref_with_bridge_abi
    obj = @engine.eval("({ a: 1, b: 'x' })")
    assert_kind_of Dommy::Js::Wasmtime::Engines::Quickjs::JsRef, obj
    assert_equal 1, obj.__js_get__("a")
    assert_equal "x", obj.__js_get__("b")
  end

  def test_global_and_document_route_into_dommy
    doc = @engine.global.__js_get__("document")
    el = doc.__js_call__("querySelector", ["#t"])
    assert_equal "Hi", el.__js_get__("textContent")
    # The same DOM is visible via Dommy's Ruby API.
    assert_equal "Hi", @engine.document.query_selector("#t").text_content
  end

  def test_js_set_writes_through_to_the_dom
    el = @engine.global.__js_get__("document").__js_call__("querySelector", ["#t"])
    el.__js_set__("textContent", "Bye")
    assert_equal "Bye", @engine.document.query_selector("#t").text_content
  end

  def test_typeof
    assert_equal "number", @engine.typeof(@engine.eval("1"))
    assert_equal "string", @engine.typeof(@engine.eval("'s'"))
    assert_equal "boolean", @engine.typeof(@engine.eval("true"))
    assert_equal "object", @engine.typeof(nil) # typeof null === "object"
    assert_equal "object", @engine.typeof(@engine.eval("({})"))
  end

  def test_strict_equal
    doc1 = @engine.global.__js_get__("document")
    doc2 = @engine.global.__js_get__("document")
    assert @engine.strict_equal(doc1, doc2), "same JS object compares equal"
    refute @engine.strict_equal(@engine.eval("({})"), @engine.eval("({})"))
  end

  def test_make_callback_routes_back_through_invoke
    cb = @engine.make_callback(42)
    cb.__js_call__("call", [nil, "arg0"]) # Function.prototype.call(thisArg, ...)
    assert_equal 1, @invoked.size
    id, args = @invoked.first
    assert_equal 42, id
    assert_equal ["arg0"], args
  end

  def test_run_until_idle_drains_timers
    @engine.eval("globalThis.__x = 0; setTimeout(() => { globalThis.__x = 5; }, 0);")
    assert_equal 0, @engine.eval("globalThis.__x")
    @engine.run_until_idle
    assert_equal 5, @engine.eval("globalThis.__x")
  end
end

# frozen_string_literal: true

require "wasmtime"
require "json"
require "dommy"

module Dommy
  module Js
    module Wasmtime
      # Raised when mruby raises an unhandled exception during eval / load_bytecode.
      class RubyError < StandardError; end

      # A wasmtime-rb host for an mruby-wasm-js build (e.g. the Lilac runtime). It
      # implements the two import modules the wasm needs:
      #
      #   - `js`                       the 25-function handle-table interop ABI,
      #                                routed to a pluggable JS engine (Engines::Quickjs
      #                                by default) whose values implement the bridge
      #                                ABI (__js_get__/__js_set__/__js_call__/__js_new__)
      #   - `wasi_snapshot_preview1`   wasmtime's bundled WASI preview1, with fd_write
      #                                shadowed to capture mruby stdout/stderr
      #
      # Extracted from lilac's reference host (test/ruby_spec/mruby_wasm.rb).
      class VM
        attr_reader :engine, :wasm_path

        # @param wasm   [String] path to the mruby-wasm-js .wasm (e.g. lilac.wasm)
        # @param engine [#global,#eval,#make_callback,#run_until_idle,…] the JS
        #   engine backing the bridge. Defaults to a QuickJS VM bound to a fresh
        #   Dommy window (real JS over a real DOM).
        def initialize(wasm:, engine: nil)
          @wasm_path = wasm.to_s
          @engine = engine || default_engine
          @stdout_buf = String.new(encoding: Encoding::BINARY)
          @stderr_buf = String.new(encoding: Encoding::BINARY)
          wire_console!

          # Handle table. id 0 = undefined/null sentinel; id 1 = the JS global
          # (engine.global). User values (primitives, JsRefs, Ruby Hash/Array)
          # live at ids >= 100.
          @handles = { 0 => nil, 1 => @engine.global }
          @next_handle = 100
          # A JS-side exception captured during js_call (a host callback can't
          # raise out of a wasmtime host function — it would unwind the wasm
          # runtime), handed back to mruby via the js_take_error import so it
          # surfaces as JS::Error instead of crashing the host.
          @pending_error = 0
          boot!
        end

        # The Dommy document/window the engine renders into — the same DOM the wasm
        # runtime mutates. Host-side tests drive and inspect it via Dommy's Ruby API.
        def document = @engine.document
        def window = @engine.window

        # Evaluate mruby source. Returns mruby's exit code (0 on success, 1 on
        # error, 2 if the compiler is absent). After the eval, drives the event
        # loop so fibers suspended on `.await` settle (the Ruby-host equivalent of
        # the browser/Node event loop unwinding the stack).
        def eval(source)
          handle = store_handle(source.b)
          rc = @js_eval_handle.call(handle, 0, 0)
          drain_async!
          rc
        ensure
          @handles.delete(handle) if handle
        end

        # Like #eval but raises RubyError on a non-zero exit code.
        def eval!(source)
          rc = eval(source)
          raise RubyError, "mruby eval failed (rc=#{rc})#{stderr_tail}" unless rc.zero?

          rc
        end

        # Load pre-compiled mrbc bytecode. Bytes flow in via the handle table as an
        # array-like (js_load_irep_handle reads length + indexed bytes).
        def load_bytecode(bytes)
          handle = store_handle(bytes.bytes)
          rc = @js_load_irep_handle.call(handle)
          drain_async!
          rc
        ensure
          @handles.delete(handle) if handle
        end

        # Drive the engine's event loop to quiescence.
        def drain_async! = @engine.run_until_idle

        # Fire an mruby block registered via `JS.callback`. `args` are Ruby values
        # (already unwrapped by the engine); they cross as a single handle to the
        # args array.
        def invoke_callback(callback_id, args)
          args_handle = store_handle(args)
          result_handle = @js_invoke_proc.call(callback_id, args_handle)
          @handles[result_handle]
        ensure
          @handles.delete(args_handle) if args_handle
          @handles.delete(result_handle) if result_handle && result_handle >= 100
        end

        # Captured stdout/stderr since the last read (clears the buffer).
        def stdout
          out = @stdout_buf
          @stdout_buf = String.new(encoding: Encoding::BINARY)
          out
        end

        def stderr
          out = @stderr_buf
          @stderr_buf = String.new(encoding: Encoding::BINARY)
          out
        end

        private

        def default_engine
          require_relative "engines/quickjs"
          Engines::Quickjs.new(invoke: method(:invoke_callback))
        end

        # mruby routes $stdout/$stderr through the JS console (mruby-wasm-js's
        # z_console_io), so puts/warn reach us via the engine's log hook, not WASI
        # fd_write. Severity error/warning → stderr.
        def wire_console!
          @engine.on_log do |log|
            buf = %i[error warning].include?(log.severity) ? @stderr_buf : @stdout_buf
            buf << log.to_s << "\n"
          end
        end

        def boot!
          @wt_engine = ::Wasmtime::Engine.new(wasm_exceptions: true)
          @module = ::Wasmtime::Module.from_file(@wt_engine, @wasm_path)

          linker = ::Wasmtime::Linker.new(@wt_engine)
          register_js!(linker)
          register_wasi!(linker)

          @store = ::Wasmtime::Store.new(@wt_engine, wasi_p1_config: ::Wasmtime::WasiConfig.new)
          @instance = linker.instantiate(@store, @module)

          init = @instance.export("_initialize")&.to_func
          init&.call

          @js_invoke_proc = @instance.export("js_invoke_proc")&.to_func
          @js_eval_handle = @instance.export("js_eval_handle")&.to_func
          @js_load_irep_handle = @instance.export("js_load_irep_handle")&.to_func
          raise "wasm is missing js_eval_handle export" unless @js_eval_handle
        end

        # ----- handle table --------------------------------------------------

        def store_handle(value)
          id = @next_handle
          @handles[id] = value
          @next_handle += 1
          id
        end

        def handle_for(value)
          value.nil? ? 0 : store_handle(value)
        end

        # ----- js.* bridge (25 functions) ------------------------------------

        def register_js!(linker)
          define = ->(name, params, results, &body) { linker.func_new("js", name, params, results, &body) }

          define.call("js_eval", %i[i32 i32], [:i32]) do |c, p, l|
            handle_for(@engine.eval(read_str(c, p, l).strip))
          end
          define.call("js_global", [], [:i32]) { |_c| 1 }
          define.call("js_release", [:i32], []) { |_c, _h| nil } # accumulate; see reference note

          define.call("js_get", %i[i32 i32 i32], [:i32]) do |c, h, p, l|
            obj = @handles[h]
            key = read_str(c, p, l)
            handle_for(host_get(obj, key))
          end

          define.call("js_set", %i[i32 i32 i32 i32], []) do |c, h, p, l, v|
            host_set(@handles[h], read_str(c, p, l), @handles[v])
            nil
          end

          define.call("js_call", %i[i32 i32 i32 i32 i32], [:i32]) do |c, h, mp, ml, ap, ac|
            obj = @handles[h]
            method = read_str(c, mp, ml)
            args = read_handle_args(c, ap, ac)
            begin
              handle_for(host_call(obj, method, args))
            rescue StandardError => e
              # Surface to mruby via js_take_error on the next bridge hit (the
              # wasm throws JS::Error); we can't raise out of a host callback.
              @pending_error = store_handle("#{e.class}: #{e.message}")
              0
            end
          end

          define.call("js_new", %i[i32 i32 i32], [:i32]) do |c, ctor, ap, ac|
            obj = @handles[ctor]
            args = read_handle_args(c, ap, ac)
            handle_for(obj.respond_to?(:__js_new__) ? obj.__js_new__(args) : nil)
          end

          define.call("js_to_string_len", [:i32], [:i32]) { |_c, h| string_value(@handles[h]).bytesize }
          define.call("js_to_string_copy", %i[i32 i32 i32], []) do |c, h, ptr, len|
            value = string_value(@handles[h])
            c.export("memory").to_memory.write(ptr, value.byteslice(0, len)) if len.positive?
            nil
          end
          define.call("js_from_string", %i[i32 i32], [:i32]) { |c, p, l| store_handle(read_str(c, p, l)) }
          define.call("js_to_int", [:i32], [:i32]) { |_c, h| Integer(@handles[h] || 0) }
          define.call("js_from_int", [:i32], [:i32]) { |_c, n| store_handle(n) }
          define.call("js_to_float", [:i32], [:f64]) { |_c, h| Float(@handles[h] || 0.0) }
          define.call("js_from_float", [:f64], [:i32]) { |_c, x| store_handle(x) }
          define.call("js_is_null", [:i32], [:i32]) { |_c, h| @handles[h].nil? ? 1 : 0 }
          define.call("js_strict_equal", %i[i32 i32], [:i32]) do |_c, a, b|
            @engine.strict_equal(@handles[a], @handles[b]) ? 1 : 0
          end
          define.call("js_typeof_len", [:i32], [:i32]) { |_c, h| @engine.typeof(@handles[h]).bytesize }
          define.call("js_typeof_copy", %i[i32 i32 i32], []) do |c, h, p, l|
            c.export("memory").to_memory.write(p, @engine.typeof(@handles[h]).byteslice(0, l))
            nil
          end
          define.call("js_inspect_len", [:i32], [:i32]) { |_c, h| inspect_value(@handles[h]).bytesize }
          define.call("js_inspect_copy", %i[i32 i32 i32], []) do |c, h, p, l|
            c.export("memory").to_memory.write(p, inspect_value(@handles[h]).byteslice(0, l))
            nil
          end
          define.call("js_instanceof", %i[i32 i32], [:i32]) do |_c, h, ctor|
            @engine.instanceof(@handles[h], @handles[ctor]) ? 1 : 0
          end
          define.call("js_make_callback", [:i32], [:i32]) do |_c, callback_id|
            store_handle(@engine.make_callback(callback_id))
          end
          define.call("js_handle_count", [], [:i32]) { |_c| @handles.size }
          define.call("js_clone", [:i32], [:i32]) { |_c, h| h }
          define.call("js_take_error", [], [:i32]) do |_c|
            err = @pending_error
            @pending_error = 0
            err
          end
        end

        # Property/method routing. JS values cross as engine refs (or Dommy
        # objects) implementing the bridge ABI; plain Ruby Array/Hash that cross
        # (callback args, host results) get array-like / hash-like access.
        def host_get(obj, key)
          return obj.__js_get__(key) if obj.respond_to?(:__js_get__)

          case obj
          when Array
            return obj.size if key == "length"

            (idx = Integer(key, exception: false)) ? obj[idx] : nil
          when Hash
            obj[key]
          end
        end

        def host_set(obj, key, value)
          return obj.__js_set__(key, value) if obj.respond_to?(:__js_set__)

          case obj
          when Array then (idx = Integer(key, exception: false)) && (obj[idx] = value)
          when Hash then obj[key] = value
          end
          nil
        end

        def host_call(obj, method, args)
          return obj.__js_call__(method, args) if obj.respond_to?(:__js_call__)
          if obj.is_a?(Array) && method == "push"
            return (args.each { |a| obj.push(a) }
                    obj.size)
          end

          nil
        end

        # ----- WASI ----------------------------------------------------------

        def register_wasi!(linker)
          ::Wasmtime::WASI::P1.add_to_linker_sync(linker)
          linker.allow_shadowing = true
          linker.func_new("wasi_snapshot_preview1", "fd_write", %i[i32 i32 i32 i32],
                          [:i32]) do |c, fd, iovs, n, nwritten|
            mem = c.export("memory").to_memory
            buf = fd == 2 ? @stderr_buf : @stdout_buf
            total = 0
            n.times do |i|
              base = iovs + (i * 8)
              ptr = mem.read(base, 4).unpack1("l<")
              len = mem.read(base + 4, 4).unpack1("l<")
              buf << mem.read(ptr, len) if len.positive?
              total += len
            end
            mem.write(nwritten, [total].pack("l<"))
            0
          end
        end

        # ----- memory + value helpers ----------------------------------------

        def read_str(caller, ptr, len)
          return "" if len <= 0

          caller.export("memory").to_memory.read(ptr, len).force_encoding("UTF-8")
        end

        def read_handle_args(caller, ptr, count)
          return [] if count.zero?

          caller.export("memory").to_memory.read(ptr, count * 4).unpack("l<*").map { |h| @handles[h] }
        end

        def string_value(value)
          case value
          when String then value
          when true then "true"
          when false then "false"
          when Integer, Float then value.to_s
          when nil then ""
          else @engine.to_string(value)
          end
        end

        def inspect_value(value)
          @engine.to_string(value)
        rescue StandardError
          value.inspect
        end

        def stderr_tail
          tail = @stderr_buf.dup.force_encoding("UTF-8")
          tail.empty? ? "" : "\n#{tail}"
        end
      end
    end
  end
end

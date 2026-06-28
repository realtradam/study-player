# Jamstack agent bridge (R1): run Ruby in the LIVE game over a localhost TCP
# socket, drained ONCE PER FRAME on the main thread (P6 — never on a socket
# callback). Dev-only, gated by JAMSTACK_BRIDGE=1 (read via Jamstack.getenv; this
# mruby has no ENV). stdout is captured by the C fd-redirect helpers
# Jamstack.__cap_begin / __cap_end because mruby's puts/print bypass $stdout.
#
# Wire protocol (R1; R4 formalizes/unifies to JSON both ways via the relay):
#   request  : one line  "<id> <code>"  with <code> escaped (\\ -> \\\\, newline
#              -> \n, tab -> \t). <id> is a token with no spaces.
#   response : one line of JSON {"id","ok","result","stdout","error","backtrace"}
#
# See .agents/knowledge/agent-bridge.md.
module Jamstack
  module Bridge
    DEFAULT_PORT  = 7621
    MAX_PER_FRAME = 16   # bound eval work per frame so the game keeps drawing

    @active  = false
    @server  = nil
    @clients = []        # [{ sock:, buf: }]
    @queue   = []        # [[id, code, sock], ...]
    @binding = nil       # optional game binding for HTML/agent-bridge REPLs

    class << self
      def active? = @active

      def enabled? = !Jamstack.getenv('JAMSTACK_BRIDGE').nil?

      # Opt the running game into exposing its local-variable scope to the
      # bridge eval (web HTML REPL, desktop bin/eval). Without this, eval runs
      # at top level and cannot read/write game locals. Mirrors Jamstack::Console
      # which is constructed with binding: binding().
      def set_binding(b)
        @binding = b
      end

      def binding
        @binding
      end

      def port
        p = Jamstack.getenv('JAMSTACK_BRIDGE_PORT')
        (p && !p.empty?) ? p.to_i : DEFAULT_PORT
      end

      def start(p = port)
        return if @active
        @server  = TCPServer.new('127.0.0.1', p)
        @clients = []
        @queue   = []
        @active  = true
        emit_log("listening on 127.0.0.1:#{p}")
      rescue => e
        @active = false
        emit_log("failed to start on #{p}: #{e.class}: #{e.message}")
      end

      # Called once per frame from Rl.while_window_open, BEFORE the game block.
      def drain
        return unless @active
        accept_new
        read_clients
        n = 0
        while n < MAX_PER_FRAME && !@queue.empty?
          id, code, sock = @queue.shift
          send_line(sock, response_json(id, eval_code(code)))
          n += 1
        end
      end

      # Run one snippet, capturing value + stdout + error. Never raises.
      # Uses the game's registered binding (set_binding) when present so HTML/agent
      # REPLs can read/write game locals; otherwise top-level eval.
      def eval_code(code)
        Jamstack.__cap_begin
        ok = true; result = nil; err = nil; bt = nil
        begin
          result = safe_inspect(@binding ? eval_in_binding(code, @binding, "(bridge)") : eval(code))
        rescue Exception => e
          ok  = false
          err = "#{e.class}: #{e.message}"
          bt  = e.backtrace || []
        ensure
          out = Jamstack.__cap_end
        end
        # Route failures into the log stream too (AFTER cap_end, so the log line
        # isn't captured as this eval's stdout).
        Jamstack::Log.error("eval error", error: err, backtrace: bt, tag: "bridge") unless ok
        { ok: ok, result: result, stdout: out.to_s, error: err, backtrace: bt }
      end

      # Eval in a binding with assignment write-back. mruby's eval opens a NEW
      # local scope, so `var = expr` would not mutate the binding's existing
      # locals — detect simple `ident = expr` assignments and route them through
      # binding.local_variable_set so the game loop's closure sees the change.
      # Compound ops (`+=`, `x.y =`, `a = b = 1`) and non-identifier LHS fall
      # through to plain eval. Shared by the HTML/agent REPL and Jamstack::Console.
      # Only locals that existed when the binding was captured can be modified.
      def eval_in_binding(line, binding, file = "(repl)")
        var_name, expr = parse_assignment(line)
        if var_name
          value = eval(expr, binding, file, 1)
          binding.local_variable_set(var_name.to_sym, value)
          value
        else
          eval(line, binding, file, 1)
        end
      end

      def parse_assignment(line)
        eq_idx = line.index("=")
        return nil unless eq_idx

        prev = eq_idx > 0 ? line[eq_idx - 1] : ""
        nxt = line[eq_idx + 1] || ""

        return nil if nxt == "="
        return nil if nxt == ">"
        return nil if "=<>!".include?(prev)
        return nil if "+-*/%".include?(prev)

        var_name = line[0...eq_idx].strip
        expr = line[(eq_idx + 1)..].strip
        return nil unless valid_identifier?(var_name)
        [var_name, expr]
      end

      def valid_identifier?(s)
        return false if s.empty?
        first = s[0]
        return false if first >= "0" && first <= "9"
        s.each_char do |c|
          return false unless ident_char?(c)
        end
        true
      end

      def ident_char?(c)
        (c >= "a" && c <= "z") || (c >= "A" && c <= "Z") ||
          (c >= "0" && c <= "9") || c == "_"
      end

      # -- Tab completion (shared by HTML/agent REPL and Jamstack::Console) --
      # Splits text at the last `::` (constant) or `.` (method) separator;
      # otherwise treats the whole text as a toplevel prefix.
      def parse_completion(text)
        if idx = text.rindex("::")
          [text[0...idx], text[(idx + 2)..], :constant]
        elsif idx = text.rindex(".")
          [text[0...idx], text[(idx + 1)..], :method]
        else
          [nil, text, :toplevel]
        end
      end

      def gather_candidates(receiver_expr, prefix, kind, binding)
        cands =
          case kind
          when :toplevel
            locals = binding.local_variables.map(&:to_s)
            meths  = binding.receiver.public_methods.map(&:to_s)
            consts = Object.constants.map(&:to_s)
            locals + meths + consts
          when :method
            recv = eval(receiver_expr, binding) rescue nil
            return [] if recv.nil?
            recv.public_methods.map(&:to_s)
          when :constant
            recv = eval(receiver_expr, binding) rescue nil
            return [] if recv.nil? || !recv.respond_to?(:constants)
            recv.constants.map(&:to_s)
          end
        cands.uniq.select { |c| c.start_with?(prefix) }.sort
      end

      def common_prefix(strings)
        return "" if strings.empty?
        prefix = strings[0]
        i = 1
        while i < strings.length
          s = strings[i]
          while !s.start_with?(prefix)
            prefix = prefix[0...-1]
            return "" if prefix.empty?
          end
          i += 1
        end
        prefix
      end

      # Completion result as a Hash. `completed` is the value to write into the
      # input on a unique match OR a common-prefix extension (nil = no change).
      # `single` distinguishes the two. `candidates` is the full filtered list
      # (the caller lists them when there's more than one).
      def complete_hash(text)
        return { ok: true, base: "", common: "", completed: nil, candidates: [], single: false } if text.to_s.empty?
        return { ok: false, error: "no binding registered (call Jamstack::Bridge.set_binding)" } unless @binding
        receiver_expr, prefix, kind = parse_completion(text)
        candidates = gather_candidates(receiver_expr, prefix, kind, @binding)
        sep = kind == :constant ? "::" : "."
        base = receiver_expr ? receiver_expr + sep : ""
        if candidates.empty?
          { ok: true, base: base, common: prefix, completed: nil, candidates: [], single: false }
        elsif candidates.length == 1
          { ok: true, base: base, common: candidates[0], completed: base + candidates[0], candidates: candidates, single: true }
        else
          common = common_prefix(candidates)
          { ok: true, base: base, common: common,
            completed: (common.length > prefix.length ? base + common : nil),
            candidates: candidates, single: false }
        end
      end

      # JSON string for the HTML/agent REPL. Call via
      #   Module.jamstack('Jamstack::Bridge.complete_json(<single-quoted text>)')
      # then double-parse: JSON.parse(env).result is this JSON string.
      def complete_json(text)
        Jamstack::JSON.generate(complete_hash(text))
      end

      # Eval and return the JSON response envelope as a String. The web jamstack_eval
      # C export calls this directly (wasm is single-threaded, so no socket/queue).
      def eval_json(code, id = nil)
        response_json(id, eval_code(code))
      end

      private

      def safe_inspect(v)
        v.inspect
      rescue Exception => e
        "#<uninspectable #{v.class}: #{e.class}>"
      end

      def accept_new
        loop do
          begin
            sock = @server.accept_nonblock
          rescue
            break                       # EAGAIN: nothing pending this frame
          end
          @clients << { sock: sock, buf: "" }
        end
      end

      def read_clients
        dead = []
        @clients.each do |c|
          loop do
            begin
              chunk = c[:sock].recv_nonblock(4096)
            rescue
              break                      # EAGAIN: no more data this frame
            end
            if chunk.nil? || chunk.empty? # peer closed
              dead << c
              break
            end
            c[:buf] << chunk
          end
          extract_lines(c)
        end
        dead.each { |c| close_client(c) }
      end

      def extract_lines(c)
        while (i = c[:buf].index("\n"))
          line = c[:buf].slice!(0, i + 1).chomp
          next if line.strip.empty?
          enqueue_line(c[:sock], line)
        end
      end

      def enqueue_line(sock, line)
        sp = line.index(' ')
        if sp
          id   = line[0...sp]
          code = unescape(line[(sp + 1)..-1])
        else
          id   = line
          code = ''
        end
        @queue << [id, code, sock]
      end

      def unescape(s)
        out = ""
        i = 0
        n = s.length
        while i < n
          ch = s[i]
          if ch == "\\" && i + 1 < n
            nx = s[i + 1]
            out << (nx == 'n' ? "\n" : nx == 't' ? "\t" : nx == 'r' ? "\r" : nx)
            i += 2
          else
            out << ch
            i += 1
          end
        end
        out
      end

      def close_client(c)
        @clients.delete(c)
        begin; c[:sock].close; rescue; end
      end

      def send_line(sock, str)
        sock.write(str)
        sock.write("\n")
      rescue
        # client vanished mid-write; reaped on next read
      end

      def response_json(id, env)
        Jamstack::JSON.generate(
          "id"        => id,
          "ok"        => env[:ok],
          "result"    => env[:result],
          "stdout"    => env[:stdout],
          "error"     => env[:error],
          "backtrace" => env[:backtrace]
        )
      end

      def emit_log(msg)
        Jamstack::Log.info(msg, tag: "bridge")
      end
    end
  end
end

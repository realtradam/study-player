module Jamstack
  class Console
    attr_reader :doc, :input, :scrollback

    KI_RETURN = 72
    KI_TAB    = 70
    KI_UP     = 91
    KI_DOWN   = 93

    def initialize(ctx, binding: binding(), toggle_key: 92, toggle_key_alt: 96, rml_path: "game/ui/console.rml")
      @binding = binding
      @toggle_key = toggle_key
      @toggle_key_alt = toggle_key_alt
      @open = false
      @history = []
      @history_index = 0
      @lines = []
      @max_lines = 200
      @bs_prev = false
      @grave_prev = false

      @doc = ctx.load_document(rml_path)
      @doc.hide
      @scrollback = @doc.element("scrollback")
      @input = @doc.element("cmd_input")

      append_info("Jamstack REPL — press \\ or ~ to toggle. Enter to eval. Up/Down for history. Tab to complete.")

      @input.on(:keydown) do |ev|
        key = ev["key_identifier"].to_i
        case key
        when KI_RETURN
          ev.stop_propagation
          submit
        when KI_TAB
          ev.stop_propagation
          complete
        when KI_UP
          ev.stop_propagation
          history_prev
        when KI_DOWN
          ev.stop_propagation
          history_next
        end
      end
    end

    def open?
      @open
    end

    def update
      ctrl = Rl.key_down?(:left_control) || Rl.key_down?(Rl::KEY_RIGHT_CONTROL)
      bs_down = Rl.key_down?(@toggle_key)
      grave_down = Rl.key_down?(@toggle_key_alt)

      bs_pressed = bs_down && !@bs_prev
      grave_pressed = grave_down && !@grave_prev
      @bs_prev = bs_down
      @grave_prev = grave_down

      return unless bs_pressed || grave_pressed

      if ctrl && @open
        shift = Rl.key_down?(:left_shift) || Rl.key_down?(Rl::KEY_RIGHT_SHIFT)
        char = if bs_pressed
                 shift ? "|" : "\\"
               else
                 shift ? "~" : "`"
               end
        @input["value"] = @input["value"].to_s + char
        @input.caret_end
      else
        toggle
      end
      while Rl.get_key_pressed != 0; end
      while Rl.get_char_pressed != 0; end
    end

    def toggle
      @open ? hide : show
    end

    def show
      @doc.show
      @doc.pull_to_front
      @input.focus
      @open = true
    end

    def hide
      @doc.hide
      @input.blur
      @open = false
    end

    def puts(msg)
      msg.to_s.split("\n").each { |line| append_line(line, "result") }
    end

    private

    def submit
      line = @input["value"].to_s
      @input["value"] = ""
      return if line.empty?

      @history << line
      @history_index = @history.length

      append_line("> #{line}", "cmd")

      begin
        result = eval_line(line)
        append_line(format_result(result), "result") unless result.nil?
      rescue => e
        append_line(format_error(e), "error")
      end
    end

    def history_prev
      return if @history.empty?
      @history_index -= 1 if @history_index > 0
      @input["value"] = @history[@history_index] || ""
      @input.caret_end
    end

    def history_next
      return if @history.empty?
      @history_index += 1 if @history_index < @history.length
      @input["value"] = @history[@history_index] || ""
      @input.caret_end
    end

    def complete
      text = @input["value"].to_s
      return if text.empty?

      receiver_expr, prefix, kind = Jamstack::Bridge.parse_completion(text)
      candidates = Jamstack::Bridge.gather_candidates(receiver_expr, prefix, kind, @binding)
      return if candidates.empty?

      sep = kind == :constant ? "::" : "."
      base = receiver_expr ? receiver_expr + sep : ""

      if candidates.length == 1
        @input["value"] = base + candidates[0]
      else
        common = Jamstack::Bridge.common_prefix(candidates)
        @input["value"] = base + common if common.length > prefix.length
        shown = candidates.length > 40 ? candidates.first(40) + ["..."] : candidates
        append_line(shown.join("  "), "info")
      end
      @input.caret_end
    end

    def eval_line(line)
      Jamstack::Bridge.eval_in_binding(line, @binding, "(console)")
    end

    def append_info(text)
      append_line(text, "info")
    end

    def append_line(text, cls)
      @lines << [cls, text]
      @lines.shift if @lines.length > @max_lines
      rebuild_scrollback
    end

    def rebuild_scrollback
      html = @lines.map { |cls, text|
        "<div class=\"line #{cls}\">#{escape_html(text)}</div>"
      }.join
      html += "<div id=\"scroll_end\"></div>"
      @scrollback.inner_rml = html
      sentinel = @scrollback.element("scroll_end")
      sentinel.scroll_into_view(false) if sentinel
    end

    def escape_html(s)
      s = s.to_s
      s = s.gsub("&", "&amp;")
      s = s.gsub("<", "&lt;")
      s = s.gsub(">", "&gt;")
      s = s.gsub("\n", "<br/>")
      s
    end

    def format_result(result)
      "#{result.inspect}"
    end

    def format_error(e)
      msg = "#{e.class}: #{e.message}"
      if e.respond_to?(:backtrace) && bt = e.backtrace
        bt = bt.is_a?(Array) ? bt : bt.to_a
        msg += "\n  " + bt.first(5).join("\n  ") unless bt.empty?
      end
      msg
    end
  end
end

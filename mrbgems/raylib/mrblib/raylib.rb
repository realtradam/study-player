# Friendly Ruby sugar layered over the generated raylib bindings (see
# tools/gen_raylib.rb). The generated API is the complete, positional surface
# (e.g. Rl.draw_text(text, x, y, size, color), Rl.init_window(w, h, title), all
# the Rl::Color / Rl::Vector2 / ... structs, Rl::KEY_* constants, etc.).
#
# This file adds the niceties from docs/API_SPEC.md: block-scoped Begin/End
# pairs, the web-safe main loop, keyword-arg helpers for a few common calls,
# symbol keys, and convenience aliases.

module Rl
  # Symbol -> keycode (letters/digits map to ASCII; named keys to KEY_* consts).
  SYMBOL_KEYS = {}
  ('a'..'z').each { |c| SYMBOL_KEYS[c.to_sym] = c.upcase.ord }
  ('0'..'9').each { |c| SYMBOL_KEYS[c.to_sym] = c.ord }
  {
    space: :KEY_SPACE, enter: :KEY_ENTER, escape: :KEY_ESCAPE, tab: :KEY_TAB,
    backspace: :KEY_BACKSPACE, up: :KEY_UP, down: :KEY_DOWN, left: :KEY_LEFT,
    right: :KEY_RIGHT, left_shift: :KEY_LEFT_SHIFT, left_control: :KEY_LEFT_CONTROL
  }.each { |sym, const| SYMBOL_KEYS[sym] = const_get(const) if const_defined?(const) }

  class << self
    def resolve_key(key)
      case key
      when Integer then key
      when Symbol  then SYMBOL_KEYS.fetch(key) { raise ArgumentError, "unknown key #{key.inspect}" }
      else raise ArgumentError, "key must be Integer or Symbol"
      end
    end

    # --- convenience aliases (spec-style names) ---
    alias_method :target_fps=,  :set_target_fps
    alias_method :master_volume=, :set_master_volume
    alias_method :frame_time,   :get_frame_time
    alias_method :time,         :get_time
    alias_method :fps,          :get_fps
    alias_method :screen_width,  :get_screen_width
    alias_method :screen_height, :get_screen_height
    alias_method :mouse_x,       :get_mouse_x
    alias_method :mouse_y,       :get_mouse_y
    alias_method :mouse_position, :get_mouse_position
    alias_method :mouse_wheel,    :get_mouse_wheel_move
    # The generator only suffixes `?` on Is* predicates; WindowShouldClose binds
    # as `window_should_close`. Provide the spec's `?` form (API_SPEC.md) — the
    # desktop seam below relies on it.
    alias_method :window_should_close?, :window_should_close

    def platform = _is_web ? :web : :desktop
    def web?     = _is_web
    def desktop? = !_is_web

    # --- input with symbol-key support (override the generated int-only ones) ---
    alias_method :_c_key_down?, :key_down?
    alias_method :_c_key_pressed?, :key_pressed?
    alias_method :_c_key_released?, :key_released?
    alias_method :_c_key_up?, :key_up?
    def key_down?(k)     = _c_key_down?(resolve_key(k))
    def key_pressed?(k)  = _c_key_pressed?(resolve_key(k))
    def key_released?(k) = _c_key_released?(resolve_key(k))
    def key_up?(k)       = _c_key_up?(resolve_key(k))

    # --- the single sanctioned loop (web-safe seam) ---
    # Also the bridge drain point: agent/console commands are queued off-frame
    # and run here, on the main thread, before the game block (P6). Desktop only
    # for R1; the web drain is wired in R4.
    #
    # Screenshot mode (desktop only): gate on JAMSTACK_SCREENSHOT=<path>. After
    # JAMSTACK_SCREENSHOT_FRAMES frames (default 30) the game block has rendered
    # and swapped, so the framebuffer holds a settled frame; take_screenshot writes
    # a pixel-exact PNG to <path>, then the loop breaks + close_window exits clean.
    # Generic — works on ANY game script with zero per-script changes (see
    # bin/screenshot). JAMSTACK_SCREENSHOT_DELAY=<seconds> adds a wall-clock wait
    # before the capture (for async/asset settle). Set JAMSTACK_SCREENSHOT_ONCE=0
    # to keep running after capture (default exits).
    def while_window_open(&block)
      ::Jamstack::Log.setup
      if ::Jamstack::Bridge.enabled?
        ::Jamstack::Bridge.start
        ::Jamstack::Live.start
      end
      if _is_web
        # Web: no TCP/.live (browser sandbox); eval arrives via the jamstack_eval
        # C export. Still advance the frame counter and log loop exceptions.
        _run_web_loop do
          ::Jamstack::Log.tick!
          begin
            block.call
          rescue Exception => e
            ::Jamstack::Log.exception(e, tag: "loop")
            raise
          end
        end
      else
        ss_path  = ::Jamstack.getenv('JAMSTACK_SCREENSHOT')
        ss_frames = 30
        ss_delay  = 0.0
        ss_once   = 1
        if (v = ::Jamstack.getenv('JAMSTACK_SCREENSHOT_FRAMES')); ss_frames = v.to_i; end
        if (v = ::Jamstack.getenv('JAMSTACK_SCREENSHOT_DELAY'));  ss_delay  = v.to_f; end
        if (v = ::Jamstack.getenv('JAMSTACK_SCREENSHOT_ONCE'));   ss_once   = v.to_i; end
        ss_done  = false
        frame_no = 0
        until window_should_close?
          ::Jamstack::Log.tick!
          ::Jamstack::Bridge.drain
          ::Jamstack::Live.poll
          begin
            block.call
          rescue Exception => e
            ::Jamstack::Log.exception(e, tag: "loop")
            raise
          end
          frame_no += 1
          next unless ss_path && !ss_done && frame_no >= ss_frames
          sleep(ss_delay) if ss_delay > 0.0
          take_screenshot(ss_path)
          ss_done = true
          ::Jamstack::Log.info("screenshot -> #{ss_path} (frame #{frame_no})") rescue nil
          break if ss_once != 0
        end
        close_window
      end
    end

    # --- block-scoped Begin/End pairs (API_SPEC 1.3), exception-safe ---
    def draw(clear_color: RAYWHITE)
      begin_drawing
      clear_background(clear_color)
      begin; yield; ensure end_drawing; end
    end

    def scissor_mode(x:, y:, width:, height:)
      begin_scissor_mode(x, y, width, height)
      begin; yield; ensure end_scissor_mode; end
    end

    def mode_2d(camera)
      begin_mode2d(camera)
      begin; yield; ensure end_mode2d; end
    end

    def mode_3d(camera)
      begin_mode3d(camera)
      begin; yield; ensure end_mode3d; end
    end

    def texture_mode(render_texture)
      begin_texture_mode(render_texture)
      begin; yield; ensure end_texture_mode; end
    end

    def blend_mode(mode)
      begin_blend_mode(mode)
      begin; yield; ensure end_blend_mode; end
    end

    def shader_mode(shader)
      begin_shader_mode(shader)
      begin; yield; ensure end_shader_mode; end
    end

    # --- keyword-arg helpers for common many-arg calls (API_SPEC 1.4/1.5) ---
    alias_method :_c_draw_text, :draw_text
    def draw_text(text:, x:, y:, font_size:, color:)
      _c_draw_text(text.to_s, x, y, font_size, color)
    end

    alias_method :_c_draw_texture_pro, :draw_texture_pro
    def draw_texture_pro(texture:, source:, dest:, origin: Vector2.new(0, 0),
                         rotation: 0, tint: WHITE)
      _c_draw_texture_pro(texture, source, dest, origin, rotation, tint)
    end
  end
end

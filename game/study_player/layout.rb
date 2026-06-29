# Study Player — layout overrides (Phase 6).
#
# Maps original UILayout config keys to RmlUi element properties, applying
# per-element position/size overrides from the config file to the loaded
# RmlUi document.
#
# --- Decision on drag-to-reposition (P4) ---
#
# The original C app (../source/src/layout_editor.c) implements per-pixel
# drag-to-reposition of every UI element on a fixed-resolution canvas. In the
# RmlUi rewrite, this approach is **deferred** for the following reasons:
#
# 1. **RmlUi is declarative.** Layout is expressed in RCSS (position: absolute;
#    left: Npx; top: Mpx) — not an imperative draw loop. Dragging an element
#    would require mutating inline `style` attributes that fight the RCSS cascade.
# 2. **RCSS already provides responsive layout.** The stylesheet is the
#    single source of truth for positioning. Users who want different positions
#    can edit the RCSS file directly (or override via config keys).
# 3. **The value of pixel-drag for a music player is marginal.** Unlike a RAD
#    form designer, a fixed set of ~10 elements benefits more from a few
#    meaningful tunables (font size, colors, panel visibility) than from
#    per-element pixel micromanagement.
# 4. **Re-implementing drag in RmlUi would be fragile.** Coordinate spaces
#    (absolute/relative/client) differ between the RmlUi event model and the
#    raylib backend's FBO scaling; a correct drag implementation would need
#    non-trivial coordinate translation (scar tissue already known to be
#    problematic — see .agents/knowledge/rmlui-binding.md §FBO size).
#
# The adapted approach:
#   - **Config file overrides** (this module): numeric position/size keys in
#     study-player.cfg are applied via Element#set_property after document load.
#   - **Settings panel** (F2): in-app controls for font_scale and volume — the
#     two settings with the highest user-facing impact.
#   - **RCSS as source of truth**: users comfortable with CSS can edit main.rcss
#     directly for deeper layout customization.
#
# This is consistent with the rewrite principle P4 (don't adopt by reputation)
# — we port the *intent* (persistent, customizable layout) without blindly
# transliterating a C drag-loop that doesn't fit the target UI framework.
#
# See: notes/study-player-rewrite-plan.md §9 (layout persistence)
#      ../source/src/layout_editor.c (original drag logic)

module StudyPlayer
  module Layout
    # Mapping from config key (Symbol) → [element_id, property_name, unit_suffix].
    #
    # Each entry tells Layout.apply how to translate a numeric config value
    # into an RmlUi element property. The unit_suffix is appended to the value
    # (e.g. "30px" for a top position, "100%" for width).
    #
    # Keys match the original UILayout C struct field names for compatibility.
    LAYOUT_MAP = {
      # Title
      title_top:        ["title",            "top",    "px"],
      title_left:       ["title",            "left",   "px"],
      title_width:      ["title",            "width",  "px"],
      title_font_size:  ["title",            "font-size", "px"],

      # Progress bar background
      bar_top:          ["progress-bar-bg",  "top",    "px"],
      bar_left:         ["progress-bar-bg",  "left",   "px"],
      bar_width:        ["progress-bar-bg",  "width",  "px"],
      bar_height:       ["progress-bar-bg",  "height", "px"],

      # Elapsed time label
      elapsed_top:      ["elapsed",          "top",    "px"],
      elapsed_left:     ["elapsed",          "left",   "px"],

      # Remaining time label
      remaining_top:    ["remaining",        "top",    "px"],
      remaining_left:   ["remaining",        "left",   "px"],

      # Progress percentage
      pct_top:          ["progress-pct",     "top",    "px"],

      # Status text
      status_top:       ["status",           "top",    "px"],
      status_font_size: ["status",           "font-size", "px"],

      # Play/pause button
      btn_play_top:     ["btn-play-pause",   "top",    "px"],
      btn_play_left:    ["btn-play-pause",   "left",   "px"],
      btn_play_size:    ["btn-play-pause",   "width",  "px"],  # (sets both w/h)

      # Portion navigation
      sec_nav_top:      ["section-counter",  "top",    "px"],
      sec_nav_left:     ["section-counter",  "left",   "px"],
      btn_prev_top:     ["btn-prev",         "top",    "px"],
      btn_prev_left:    ["btn-prev",         "left",   "px"],
      btn_next_top:     ["btn-next",         "top",    "px"],
      btn_next_left:    ["btn-next",         "left",   "px"],

      # Smart Play button
      smart_play_top:   ["btn-smart",        "top",    "px"],
      smart_play_left:  ["btn-smart",        "left",   "px"],

      # Help text
      help_top:         ["help-text",        "top",    "px"],
      help_left:        ["help-text",        "left",   "px"],

      # Study mode checkbox
      study_box_top:    ["study-mode-box",   "top",    "px"],
      study_box_left:   ["study-mode-box",   "left",   "px"],
    }.freeze

    # Element IDs that use "width" and "height" in sync (square elements).
    # When btn_play_size is set, we apply it to both width and height.
    SYNC_SIZE_IDS = {
      btn_play_size: ["btn-play-pause", "width", "height"],
    }.freeze

    # ------------------------------------------------------------------
    # Public API
    # ------------------------------------------------------------------

    # Apply layout overrides from a config hash to the loaded RmlUi document.
    #
    # doc      — an Rml::Document (returned by context.load_document)
    # settings — Hash with Symbol keys (from Config.load)
    #
    # Only settings that appear in LAYOUT_MAP are applied.
    def self.apply(doc, settings)
      return unless doc

      settings.each do |key, value|
        next unless value

        # Check for sync-size keys first (e.g. btn_play_size → both width + height)
        if (sync = SYNC_SIZE_IDS[key])
          el_id, prop_w, prop_h = sync
          el = doc.element(el_id)
          next unless el
          v_str = "#{value}px"
          el.set_property(prop_w, v_str)
          el.set_property(prop_h, v_str)
          next
        end

        map_entry = LAYOUT_MAP[key]
        next unless map_entry

        el_id, prop, unit = map_entry
        el = doc.element(el_id)
        next unless el

        v_str = "#{value}#{unit}"
        el.set_property(prop, v_str)
      end
    end

    # Apply font_scale to the body element via a global style override.
    # The <body> tag has id="body-root" so we can set its properties.
    def self.apply_font_scale(doc, scale)
      return unless doc
      return if scale <= 0 || scale > 5.0

      base = 18  # matches main.rcss body font-size
      new_size = (base * scale).round
      new_size = 10 if new_size < 10
      new_size = 96 if new_size > 96

      root = doc.element("body-root")
      return unless root

      root.set_property("font-size", "#{new_size}px")
    end
  end
end

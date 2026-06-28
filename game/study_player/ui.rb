# Study Player — RmlUi UI wrapper (Phase 5: full RmlUi player UI).
#
# Creates the Rml::Context, data model, loads the document, and provides
# per-frame sync from flecs state to the RmlUi data model.
#
# The data model is bound by name "player" in both the RML (data-model="player")
# and here. Events from RML data-event-* attributes call back into this module,
# which mutates flecs component state (seek_target, playing, study_mode, etc.).
#
# See: notes/study-player-rewrite-plan.md §6 (RmlUi UI structure)
#      docs/API_SPEC_RMLUI.md (RmlUi API)
#      .agents/knowledge/rmlui-binding.md (known quirks: left-not-right, FBO size)

module StudyPlayer
  class UI
    HELP_TEXT = "SPACE: play/pause  LEFT/RIGHT: ±5s  V/B: prev/next portion  S: hold override  M: study mode  0-9: jump  ESC: quit".freeze

    attr_reader :context, :model, :doc

    def initialize(runtime, components)
      @runtime    = runtime
      @comps      = components
      @player_ent = runtime.player_entity
      @smart_play_mouse_held = false

      # --- RmlUi setup ---
      Rml.load_font("game/ui/LatoLatin-Regular.ttf")
      Rml.load_font("game/ui/LatoLatin-Bold.ttf")
      Rml.load_font("game/ui/MononokiNerdFontMono-Regular.ttf")

      @context = Rml::Context.new("study-player")
      @model   = build_model
      @doc     = @context.load_document("game/study_player/ui/main.rml")
      @doc.show
    end

    # Called by the event system to check if the mouse is holding smart-play.
    def smart_play_held?
      @smart_play_mouse_held
    end

    # ------------------------------------------------------------------
    # Per-frame sync: marks all bound variables dirty so the view
    # re-reads flecs state on the next update.
    # ------------------------------------------------------------------
    def sync
      @model.dirty_all
    end

    # ------------------------------------------------------------------
    # Lifecycle
    # ------------------------------------------------------------------
    def process_input
      @context.process_input
    end

    def render
      @context.update
      @context.render
    end

    private

    # ------------------------------------------------------------------
    # Build the data model
    # ------------------------------------------------------------------
    def build_model
      ctx = @context
      af_c = @comps[:audio_file]
      pb_c = @comps[:playback_state]
      ss_c = @comps[:study_state]
      pe   = @player_ent
      rt   = @runtime

      ctx.data_model("player") do |m|
        # -- One-way computed bindings (read each frame from flecs) --
        m.bind(:loaded) do
          pb = pe.get(pb_c)
          pb && pb[:loaded] ? true : false
        end

        m.bind(:file_name) do
          af = pe.get(af_c)
          path = af[:path].to_s
          path.empty? ? "" : File.basename(path)
        end

        m.bind(:elapsed_str) do
          pb = pe.get(pb_c)
          Core.format_time(pb ? pb[:current_time] : 0.0)
        end

        m.bind(:total_str) do
          af = pe.get(af_c)
          Core.format_time(af[:duration])
        end

        m.bind(:remain_str) do
          pb = pe.get(pb_c)
          af = pe.get(af_c)
          rem = (af[:duration] - (pb ? pb[:current_time] : 0.0))
          rem = 0.0 if rem < 0.0
          Core.format_time(rem)
        end

        m.bind(:progress_pct) do
          pb = pe.get(pb_c)
          af = pe.get(af_c)
          dur = af[:duration]
          if dur > 0 && pb
            (Core.time_to_ratio(pb[:current_time], dur) * 100.0).to_i
          else
            0
          end
        end

        m.bind(:progress_ratio) do
          pb = pe.get(pb_c)
          af = pe.get(af_c)
          dur = af[:duration]
          ratio = (dur > 0 && pb) ? Core.time_to_ratio(pb[:current_time], dur) : 0.0
          # Return as percentage string for style="width: ...%;"
          "#{(ratio * 100.0).round(1)}%"
        end

        m.bind(:status_text) do
          pb = pe.get(pb_c)
          (pb && pb[:playing]) ? "PLAYING" : "PAUSED"
        end

        m.bind(:status_alert) do
          pb = pe.get(pb_c)
          ss = pe.get(ss_c)
          (pb && pb[:playing] && ss && ss[:was_in_silence]) ? true : false
        end

        m.bind(:playing) do
          pb = pe.get(pb_c)
          pb && pb[:playing] ? true : false
        end

        m.bind(:portion_label) do
          pb = pe.get(pb_c)
          af = pe.get(af_c)
          regions = rt.silence_regions
          dur = af[:duration]
          if pb && regions && regions.length >= 0 && dur > 0
            pos_norm = Core.time_to_ratio(pb[:current_time], dur)
            current  = Core.current_speaking_portion(regions, pos_norm)
            total    = Core.total_speaking_portions(regions)
            "#{current + 1}/#{total}"
          else
            "-/-"
          end
        end

        m.bind(:smart_play_held) do
          @smart_play_mouse_held
        end

        m.bind(:help_text) { HELP_TEXT }

        # -- Two-way values --
        m.value(:study_mode, false)

        # -- Controller events --
        m.event(:toggle_play) do
          pb = pe.get(pb_c)
          next unless pb
          if pb[:loaded]
            if pb[:playing]
              rt.audio.pause
              pb[:playing] = false
            else
              rt.audio.resume
              pb[:playing] = true
            end
            pe.set(pb_c, pb)
          end
        end

        m.event(:prev_portion) do
          pb = pe.get(pb_c)
          af = pe.get(af_c)
          regions = rt.silence_regions
          dur = af[:duration]
          next unless pb && pb[:loaded] && regions && dur > 0
          pos_norm = Core.time_to_ratio(pb[:current_time], dur)
          current  = Core.current_speaking_portion(regions, pos_norm)
          prev_portion = current - 1
          prev_portion = 0 if prev_portion < 0
          target = Core.portion_seek_target(dur, regions, prev_portion)
          pb[:seek_target]  = target
          pb[:seek_pending] = true
          pe.set(pb_c, pb)
        end

        m.event(:next_portion) do
          pb = pe.get(pb_c)
          af = pe.get(af_c)
          regions = rt.silence_regions
          dur = af[:duration]
          next unless pb && pb[:loaded] && regions && dur > 0
          pos_norm = Core.time_to_ratio(pb[:current_time], dur)
          current  = Core.current_speaking_portion(regions, pos_norm)
          total    = Core.total_speaking_portions(regions)
          np = current + 1
          np = total - 1 if np >= total
          target = Core.portion_seek_target(dur, regions, np)
          pb[:seek_target]  = target
          pb[:seek_pending] = true
          pe.set(pb_c, pb)
        end

        m.event(:smart_down) do
          @smart_play_mouse_held = true
          # Auto-play if paused (matching original behavior)
          pb = pe.get(pb_c)
          if pb && pb[:loaded] && !pb[:playing]
            rt.audio.resume
            pb[:playing] = true
            pe.set(pb_c, pb)
          end
        end

        m.event(:smart_up) do
          @smart_play_mouse_held = false
        end

        m.event(:seek_bar) do |ev|
          pb = pe.get(pb_c)
          af = pe.get(af_c)
          dur = af[:duration]
          next unless pb && pb[:loaded] && dur > 0

          # Compute seek ratio from click position on the progress bar.
          # The event target is the #progress-bar-bg element.
          el = ev.current
          if el
            x     = ev.mouse_x - el.absolute_left
            ratio = (x.to_f / el.client_width).clamp(0.0, 1.0)
            target = Core.ratio_to_seek(ratio, dur)
            pb[:seek_target]  = target
            pb[:seek_pending] = true
            pe.set(pb_c, pb)
          end
        end
      end
    end
  end
end

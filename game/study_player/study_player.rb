# Study Player — composition root (Phase 2: audio core).
#
# Run:
#   ./zig-out/bin/game game/study_player/study_player.rb [/path/to/audio.mp3]
#
# With an audio file arg: opens straight into the player view with the file
# loaded and playing. Without an arg: shows the "no file loaded" splash.
#
# Note: all modules are inlined because mruby's default gembox lacks
# require/require_relative/load. Multi-file loading (with mruby-require)
# is a Phase 3 consideration. Individual module files are retained on disk
# as design documentation and for future use when a loader gem is added.
#
# See: notes/study-player-rewrite-plan.md (full design)

# =============================================================================
# Module: Core — Pure domain logic (no side effects)
# See: notes/study-player-rewrite-plan.md §8 (pure core API sketch)
# =============================================================================

module StudyPlayer
  module Core
    # Format seconds as a display string.
    #   - < 1 hour:  "M:SS"    (e.g. "3:45", "12:03")
    #   - >= 1 hour: "H:MM:SS" (e.g. "1:23:45")
    def self.format_time(total_seconds)
      total = total_seconds.to_i
      hours   = total / 3600
      minutes = (total % 3600) / 60
      seconds = total % 60

      if hours > 0
        format("%d:%02d:%02d", hours, minutes, seconds)
      else
        format("%d:%02d", minutes, seconds)
      end
    end

    # Seek target utilities (pure math, no audio I/O).
    #
    # clamp_seek_target ensures the seek position stays within [0, duration].
    def self.clamp_seek_target(target_seconds, duration)
      return 0.0 if duration <= 0.0
      target_seconds.clamp(0.0, duration)
    end

    # Compute absolute seek target from a ratio (0.0 to 1.0).
    def self.ratio_to_seek(ratio, duration)
      clamp_seek_target(ratio.to_f * duration, duration)
    end

    # Compute absolute seek target from an offset (+/- seconds).
    def self.offset_to_seek(current_time, offset_seconds, duration)
      clamp_seek_target(current_time + offset_seconds, duration)
    end

    # Compute ratio (0.0–1.0) from a time in seconds.
    def self.time_to_ratio(current_time, duration)
      return 0.0 if duration <= 0.0
      (current_time / duration).clamp(0.0, 1.0)
    end
  end
end

# =============================================================================
# Module: AudioAdapter — Rl::Music lifecycle wrapper (imperative shell)
# See: notes/study-player-rewrite-plan.md §5 (audio loading)
# =============================================================================

module StudyPlayer
  class AudioAdapter
    attr_reader :music, :path

    def initialize
      @music = nil
      @path  = nil
    end

    # Load an audio file. Returns true on success, false on failure.
    def load(path)
      unload if @music
      m = Rl.load_music_stream(path)
      if m && Rl.music_valid?(m)
        @music = m
        @path  = path
        true
      else
        @music = nil
        @path  = nil
        false
      end
    end

    def unload
      return unless @music
      Rl.stop_music_stream(@music)
      Rl.unload_music_stream(@music)
      @music = nil
      @path  = nil
    end

    def loaded?
      !!@music
    end

    def play
      return unless @music
      Rl.play_music_stream(@music)
    end

    def pause
      return unless @music
      Rl.pause_music_stream(@music)
    end

    def resume
      return unless @music
      Rl.resume_music_stream(@music)
    end

    def stop
      return unless @music
      Rl.stop_music_stream(@music)
    end

    def playing?
      return false unless @music
      Rl.music_stream_playing?(@music)
    end

    # Seek to an absolute position in seconds.
    def seek(position_seconds)
      return unless @music
      Rl.seek_music_stream(@music, position_seconds)
    end

    # Update the stream (must be called every frame while playing).
    def update
      return unless @music
      Rl.update_music_stream(@music)
    end

    # Get current playback position in seconds.
    def current_time
      return 0.0 unless @music
      Rl.get_music_time_played(@music)
    end

    # Get total duration in seconds.
    def duration
      return 0.0 unless @music
      Rl.get_music_time_length(@music)
    end

    # Set volume (0.0 to 1.0).
    def volume=(v)
      return unless @music
      Rl.set_music_volume(@music, v)
    end

    # Set playback speed / pitch (1.0 is normal).
    def pitch=(p)
      return unless @music
      Rl.set_music_pitch(@music, p)
    end
  end
end

# =============================================================================
# Module: Components — Flecs component declarations
# See: notes/study-player-rewrite-plan.md §3 (flecs component/state model)
# =============================================================================

module StudyPlayer
  # Declare components on a Flecs::World. Returns a Hash of component handles.
  def self.declare_components(world)
    {
      audio_file:     world.struct("AudioFile",     "{string path; float duration;}"),
      playback_state: world.struct("PlaybackState", "{bool loaded; bool playing; float current_time; int32_t skip_auto_update; bool seek_pending; float seek_target;}"),
      study_state:    world.struct("StudyState",    "{bool study_mode; bool was_in_silence; int32_t last_silence_idx; bool smart_play_held;}"),
      layout_dirty:   world.struct("LayoutDirty",   "{bool value;}"),
      needs_load:     world.tag("NeedsLoad"),
    }
  end
end

# =============================================================================
# Module: InputAdapter — Keyboard input handler
# See: notes/study-player-rewrite-plan.md §7 (non-blocking seek design)
# =============================================================================

module StudyPlayer
  module InputAdapter
    # Key bindings (from ../source/README.md):
    #   SPACE          — play/pause toggle
    #   LEFT / RIGHT   — seek -5s / +5s
    #   UP / DOWN      — seek -15s / +15s
    #   J / L          — seek -10% / +10%
    #   0 .. 9         — seek to N×10% of duration
    #   ESC            — quit
    #
    # Phase 4 adds:  V/B (prev/next portion), SMART_PLAY hold override

    SEEK_SMALL   = 5.0    # seconds: LEFT / RIGHT
    SEEK_LARGE   = 15.0   # seconds: UP / DOWN
    SEEK_PCT_STEP = 0.10  # 10%: J / L

    def self.build_system(world, player_entity, runtime, playback_state)
      world.system("Input", with: [], phase: Flecs::PRE_UPDATE) do
        pb = player_entity.get(playback_state)
        next unless pb

        # --- Play/pause toggle ---
        if Rl.key_pressed?(:space)
          if pb[:playing]
            runtime.audio.pause
            pb[:playing] = false
          elsif pb[:loaded]
            runtime.audio.resume
            pb[:playing] = true
          end
          player_entity.set(playback_state, pb)
        end

        # --- Seek: small step ---
        duration = runtime.audio.duration
        if Rl.key_pressed?(:right)
          target = StudyPlayer::Core.offset_to_seek(pb[:current_time], SEEK_SMALL, duration)
          pb[:seek_target] = target
          pb[:seek_pending] = true
          player_entity.set(playback_state, pb)
        elsif Rl.key_pressed?(:left)
          target = StudyPlayer::Core.offset_to_seek(pb[:current_time], -SEEK_SMALL, duration)
          pb[:seek_target] = target
          pb[:seek_pending] = true
          player_entity.set(playback_state, pb)
        end

        # --- Seek: large step ---
        if Rl.key_pressed?(:up)
          target = StudyPlayer::Core.offset_to_seek(pb[:current_time], SEEK_LARGE, duration)
          pb[:seek_target] = target
          pb[:seek_pending] = true
          player_entity.set(playback_state, pb)
        elsif Rl.key_pressed?(:down)
          target = StudyPlayer::Core.offset_to_seek(pb[:current_time], -SEEK_LARGE, duration)
          pb[:seek_target] = target
          pb[:seek_pending] = true
          player_entity.set(playback_state, pb)
        end

        # --- Seek: percentage jump (J/L) ---
        if Rl.key_pressed?(:j) && duration > 0
          target = StudyPlayer::Core.offset_to_seek(pb[:current_time], SEEK_PCT_STEP * duration, duration)
          pb[:seek_target] = target
          pb[:seek_pending] = true
          player_entity.set(playback_state, pb)
        elsif Rl.key_pressed?(:l) && duration > 0
          target = StudyPlayer::Core.offset_to_seek(pb[:current_time], -SEEK_PCT_STEP * duration, duration)
          pb[:seek_target] = target
          pb[:seek_pending] = true
          player_entity.set(playback_state, pb)
        end

        # --- Seek: 0..9 → N×10% ---
        if duration > 0
          (0..9).each do |n|
            key = n.to_s.to_sym
            if Rl.key_pressed?(key)
              target = StudyPlayer::Core.ratio_to_seek(n * 0.1, duration)
              pb[:seek_target] = target
              pb[:seek_pending] = true
              player_entity.set(playback_state, pb)
            end
          end
        end
      end
    end
  end
end

# =============================================================================
# System: LoadSystem — Reacts to NeedsLoad tag
# See: notes/study-player-rewrite-plan.md §5 (audio loading from argv)
# =============================================================================

module StudyPlayer
  class LoadSystem
    def self.build(world, player_entity, runtime, audio_file_comp, playback_state, needs_load_tag)
      world.system("LoadAudio", with: [audio_file_comp], phase: Flecs::PRE_UPDATE) do |eid, af|
        # Only react to entities that also have NeedsLoad
        ent = world.entity_for(eid)
        next unless ent.has?(needs_load_tag)

        path = af[:path].to_s
        next if path.empty?

        success = runtime.audio.load(path)
        if success
          duration = runtime.audio.duration
          pb = player_entity.get(playback_state) || {}
          pb[:loaded]       = true
          pb[:playing]      = true   # auto-play on load
          pb[:current_time] = 0.0
          pb[:skip_auto_update] = 0
          pb[:seek_pending] = false
          pb[:seek_target]  = 0.0
          player_entity.set(playback_state, pb)

          # Also update the AudioFile component with actual duration
          af[:duration] = duration
          ent.set(audio_file_comp, af)

          # Start playback
          runtime.audio.play
        else
          # Load failed — clear the file path
          af[:path] = ""
          ent.set(audio_file_comp, af)
        end

        # Clear the NeedsLoad tag (one-shot)
        ent.remove(needs_load_tag)
      end
    end
  end
end

# =============================================================================
# System: UpdateSystem — Per-frame audio update + time management
# See: notes/study-player-rewrite-plan.md §7 (non-blocking seek design)
# =============================================================================

module StudyPlayer
  class UpdateSystem
    def self.build(world, player_entity, runtime, playback_state)
      world.system("Update", with: [], phase: Flecs::ON_UPDATE) do
        pb = player_entity.get(playback_state)
        next unless pb && pb[:loaded]

        audio = runtime.audio

        # Always pump the stream (needed even when paused to keep buffers filled)
        audio.update if audio.loaded?

        if pb[:playing] && audio.loaded?
          if pb[:skip_auto_update] > 0
            # Non-blocking seek cooldown: skip sampling current time from the
            # audio engine for N frames so it catches up without visual flicker.
            pb[:skip_auto_update] -= 1
          else
            # Normal time sampling
            pb[:current_time] = audio.current_time
          end

          # End-of-track detection: pause when playback reaches the end
          duration = audio.duration
          if duration > 0 && pb[:current_time] >= duration - 0.1
            audio.pause
            pb[:playing]  = false
            pb[:current_time] = duration
          end

          player_entity.set(playback_state, pb)
        end
      end
    end
  end
end

# =============================================================================
# System: SeekSystem — Applies pending seek (non-blocking)
# See: notes/study-player-rewrite-plan.md §7 (non-blocking seek design)
# =============================================================================

module StudyPlayer
  class SeekSystem
    # Number of frames to skip current_time auto-update after a seek.
    # 3 frames at 60 fps = ~50 ms — enough for raylib's miniaudio stream
    # to flush and report a stable time.
    SKIP_FRAMES = 3

    def self.build(world, player_entity, runtime, playback_state)
      world.system("ApplySeek", with: [], phase: Flecs::PRE_UPDATE) do
        pb = player_entity.get(playback_state)
        next unless pb && pb[:loaded] && pb[:seek_pending]

        audio = runtime.audio
        next unless audio.loaded?

        target = pb[:seek_target]

        # Apply the seek
        audio.seek(target)

        # Update component state
        pb[:current_time]     = target
        pb[:skip_auto_update] = SKIP_FRAMES
        pb[:seek_pending]     = false

        player_entity.set(playback_state, pb)
      end
    end
  end
end

# =============================================================================
# Composition Root — init, components, systems, main loop
# =============================================================================

module StudyPlayer
  SCREEN_W = 1280
  SCREEN_H = 720

  # Runtime: owns non-serializable handles (Rl::Music) and the flecs world.
  class Runtime
    attr_accessor :world, :player_entity, :audio, :components
    def initialize(world:, player_entity:, audio:, components:)
      @world = world
      @player_entity = player_entity
      @audio = audio
      @components = components
    end
  end

  def self.run
    Rl.init_window(SCREEN_W, SCREEN_H, "Study Player")
    Rl.target_fps = 60
    Rl.init_audio_device

    # --- Flecs world + components ---
    world = Flecs::World.new
    comps = declare_components(world)
    af = comps[:audio_file]
    pb = comps[:playback_state]
    ss = comps[:study_state]
    ld = comps[:layout_dirty]
    nl = comps[:needs_load]

    # --- Singleton entity ---
    player_entity = world.entity("study_player")
      .set(af, { path: "", duration: 0.0 })
      .set(pb, { loaded: false, playing: false, current_time: 0.0,
                 skip_auto_update: 0, seek_pending: false, seek_target: 0.0 })
      .set(ss, { study_mode: false, was_in_silence: false,
                 last_silence_idx: -1, smart_play_held: false })
      .set(ld, { value: false })

    # --- Audio adapter ---
    audio = AudioAdapter.new

    # --- Runtime ---
    runtime = Runtime.new(
      world: world,
      player_entity: player_entity,
      audio: audio,
      components: comps,
    )

    # --- Register systems ---
    LoadSystem.build(world, player_entity, runtime, af, pb, nl)
    SeekSystem.build(world, player_entity, runtime, pb)
    InputAdapter.build_system(world, player_entity, runtime, pb)
    UpdateSystem.build(world, player_entity, runtime, pb)

    # --- File drop check system (drag-and-drop fallback) ---
    world.system("CheckFileDrop", with: [], phase: Flecs::PRE_UPDATE) do
      if Rl.file_dropped?
        files = Rl.load_dropped_files
        if files && files.count > 0
          path = files.path_at(0)
          if path && !path.empty?
            ent = player_entity
            ent.set(af, { path: path, duration: 0.0 })
            ent.add(nl)
          end
        end
        Rl.unload_dropped_files(files)
      end
    end

    # --- Audio file from ARGV (Phase 2: opens straight into player view) ---
    audio_arg = nil
    begin
      audio_arg = ARGV[0] if ARGV && ARGV.length > 0
    rescue
    end
    if audio_arg && !audio_arg.to_s.empty?
      path = audio_arg.to_s
      player_entity
        .set(af, { path: path, duration: 0.0 })
        .add(nl)
    end

    # --- Main loop ---
    Rl.while_window_open do
      dt = Rl.frame_time

      # Check for quit
      if Rl.key_pressed?(:escape)
        Rl.close_window
        break
      end

      # Run ECS systems
      world.progress(dt)

      # --- Draw: minimal on-screen status for Phase 2 verification ---
      Rl.draw(clear_color: Rl::Color.new(26, 26, 46, 255)) do
        pb_current = player_entity.get(pb)
        af_current = player_entity.get(af)

        if pb_current && pb_current[:loaded]
          # Player view: show filename + time + play state
          duration   = af_current[:duration]
          pos        = pb_current[:current_time]
          playing    = pb_current[:playing]
          skip_ct    = pb_current[:skip_auto_update]
          seeking    = pb_current[:seek_pending]
          path       = af_current[:path].to_s

          # Filename (basename only)
          fname = File.basename(path)
          elapsed_str = Core.format_time(pos)
          total_str   = Core.format_time(duration)
          ratio       = Core.time_to_ratio(pos, duration)

          state_str = if seeking
                        "SEEKING..."
                      elsif skip_ct > 0
                        "SEEK SETTLE (#{skip_ct})"
                      elsif playing
                        "PLAYING"
                      else
                        "PAUSED"
                      end

          # Title
          Rl.draw_text(text: fname,
                       x: SCREEN_W / 2 - 200, y: 260, font_size: 24,
                       color: Rl::Color.new(234, 234, 234, 255))

          # Time display
          time_text = "#{elapsed_str} / #{total_str}"
          Rl.draw_text(text: time_text,
                       x: SCREEN_W / 2 - 150, y: 310, font_size: 40,
                       color: Rl::Color.new(200, 200, 210, 255))

          # Progress bar (simple rects)
          bar_x = 100; bar_y = 380; bar_w = SCREEN_W - 200; bar_h = 12
          Rl.draw_rectangle(bar_x, bar_y, bar_w, bar_h, Rl::Color.new(40, 40, 60, 255))
          Rl.draw_rectangle(bar_x, bar_y, (bar_w * ratio).to_i, bar_h,
                            Rl::Color.new(233, 69, 96, 255))

          # Play state
          Rl.draw_text(text: state_str,
                       x: SCREEN_W / 2 - 60, y: 420, font_size: 18,
                       color: playing ? Rl::Color.new(100, 200, 100, 255) : Rl::Color.new(200, 100, 100, 255))

          # Controls help
          Rl.draw_text(text: "SPACE: play/pause  LEFT/RIGHT: -5s/+5s  UP/DOWN: -15s/+15s  J/L: -10%/+10%  0-9: n×10%  ESC: quit",
                       x: 20, y: SCREEN_H - 60, font_size: 14,
                       color: Rl::Color.new(120, 120, 140, 255))

          # Debug: skip_auto_update counter
          if skip_ct > 0
            Rl.draw_text(text: "seek cooldown: #{skip_ct}",
                         x: 20, y: SCREEN_H - 90, font_size: 12,
                         color: Rl::Color.new(200, 200, 60, 255))
          end
        else
          # Splash: no file loaded
          Rl.draw_text(text: "Study Player",
                       x: SCREEN_W / 2 - 180, y: 260, font_size: 60,
                       color: Rl::Color.new(234, 234, 234, 255))
          Rl.draw_text(text: "Drop an audio file or run with: game study_player.rb <audio.mp3>",
                       x: SCREEN_W / 2 - 330, y: 380, font_size: 18,
                       color: Rl::Color.new(233, 69, 96, 255))
          Rl.draw_text(text: "SPACE: start  ESC: quit",
                       x: SCREEN_W / 2 - 100, y: 430, font_size: 16,
                       color: Rl::Color.new(120, 120, 140, 255))
        end
      end
    end

    # --- Shutdown ---
    audio.unload if audio.loaded?
    Rl.close_audio_device
  end
end

StudyPlayer.run

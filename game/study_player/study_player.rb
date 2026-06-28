# Study Player — composition root (Phase 3: silence detection + portion navigation).
#
# Run:
#   ./zig-out/bin/game game/study_player/study_player.rb [/path/to/audio.mp3]
#
# With an audio file arg: opens straight into the player view with the file
# loaded and playing. Without an arg: shows the "no file loaded" splash.
#
# Note: all modules are inlined because mruby's default gembox lacks
# require/require_relative/load. Individual module files are retained on disk
# as design documentation and for future use when a loader gem is added.
#
# See: notes/study-player-rewrite-plan.md (full design)

# =============================================================================
# Module: Core — Pure domain logic (no side effects)
# Ported from: ../source/src/study.h + study.c
# See: notes/study-player-rewrite-plan.md §8 (pure core API sketch)
# =============================================================================

module StudyPlayer
  module Core
    # ------------------------------------------------------------------
    # Time formatting
    # ------------------------------------------------------------------

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

    # ------------------------------------------------------------------
    # Seek target utilities (pure math, no audio I/O)
    # ------------------------------------------------------------------

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

    # ------------------------------------------------------------------
    # Silence detection (pure algorithm)
    # Ported from ../source/src/study.c study_detect_silence
    # ------------------------------------------------------------------

    SILENCE_THRESHOLD   = 0.015  # amplitude below which a chunk is "silent"
    SILENCE_MIN_DURATION = 0.75   # seconds: minimum gap to count as silence
    PADDING_SECONDS     = 0.25   # breathing room added to each side of silence
    CHUNK_SECONDS       = 0.01   # scan resolution (~10ms chunks)
    LEAD_FRAMES         = 2      # frames into padding zone for portion seek target

    # Detect silence regions from raw float samples.
    #
    # samples     — Array of Float (mono, 32-bit, one per frame)
    # sample_rate — Integer (Hz)
    # threshold   — amplitude below which a chunk is "silent" (default 0.015)
    # min_duration — minimum silence length in seconds (default 0.75)
    #
    # Returns Array of Hashes: [{start:, end:}, ...] where start/end are
    # normalized positions (0.0..1.0) relative to total frame count.
    def self.detect_silence(samples, sample_rate,
                             threshold: SILENCE_THRESHOLD,
                             min_duration: SILENCE_MIN_DURATION)
      total_frames = samples.length
      return [] if total_frames == 0

      chunk_size = (sample_rate * CHUNK_SECONDS).to_i
      chunk_size = 1 if chunk_size < 1
      min_frames = min_duration * sample_rate

      regions = []
      in_silence = false
      silence_start = 0

      i = 0
      while i < total_frames
        range_end = i + chunk_size
        range_end = total_frames if range_end > total_frames

        # Find peak amplitude in this chunk
        peak = 0.0
        j = i
        while j < range_end
          v = samples[j]
          v = -v if v < 0.0
          peak = v if v > peak
          j += 1
        end

        if peak < threshold
          unless in_silence
            silence_start = i
            in_silence = true
          end
        else
          if in_silence
            len = i - silence_start
            if len >= min_frames
              regions << {
                start: silence_start.to_f / total_frames,
                end:   i.to_f / total_frames,
              }
            end
            in_silence = false
          end
        end

        i = range_end
      end

      # Close any trailing silence
      if in_silence
        len = total_frames - silence_start
        if len >= min_frames
          regions << {
            start: silence_start.to_f / total_frames,
            end:   1.0,
          }
        end
      end

      regions
    end

    # Apply padding: shrink each silence region by `padding` seconds on each side.
    # Regions that collapse (start >= end) are removed.
    #
    # regions  — Array of {start:, end:} (normalized)
    # duration — total audio duration in seconds
    # padding  — seconds to shrink from each side (default 0.25)
    #
    # Returns a NEW Array of shrunk regions. Does not mutate input.
    def self.pad_silence_regions(regions, duration, padding: PADDING_SECONDS)
      return [] if duration <= 0.0
      return regions.dup if regions.empty?

      pad_norm = padding / duration
      result = []

      regions.each do |r|
        s = r[:start] + pad_norm
        e = r[:end]   - pad_norm
        if s < e
          result << { start: s, end: e }
        end
      end

      result
    end

    # Full analysis pipeline: detect raw gaps, then pad them.
    # Returns padded silence regions.
    def self.analyze_silence(samples, sample_rate, duration,
                             threshold: SILENCE_THRESHOLD,
                             min_duration: SILENCE_MIN_DURATION,
                             padding: PADDING_SECONDS)
      raw = detect_silence(samples, sample_rate,
                           threshold: threshold,
                           min_duration: min_duration)
      pad_silence_regions(raw, duration, padding: padding)
    end

    # ------------------------------------------------------------------
    # Portion navigation (pure, ported from study.c)
    # ------------------------------------------------------------------

    # Return the index of the silence region containing pos (normalized 0..1),
    # or -1 if none.
    def self.find_silence_at(regions, pos)
      regions.each_with_index do |r, i|
        return i if pos >= r[:start] && pos < r[:end]
      end
      -1
    end

    # Start position (normalized) of speaking portion N (0-based).
    # Portion 0 starts at 0.0; portion N starts at silence[N-1].end.
    def self.speaking_portion_start(regions, portion)
      return 0.0 if portion <= 0
      if portion > regions.length
        return regions.length > 0 ? regions.last[:end] : 0.0
      end
      regions[portion - 1][:end]
    end

    # Which speaking portion (0-based) the current position falls in.
    # During silence, returns the portion that just ended.
    def self.current_speaking_portion(regions, pos)
      portion = 0
      regions.each_with_index do |r, i|
        if pos >= r[:end]
          portion = i + 1
        else
          break
        end
      end
      portion
    end

    # Total number of speaking portions (always silence_count + 1).
    def self.total_speaking_portions(regions)
      regions.length + 1
    end

    # Seek target (seconds) for jumping to the start of a speaking portion.
    # Lands `lead_frames` render frames into the padding zone (~33ms at 60fps).
    def self.portion_seek_target(duration, regions, portion,
                                 lead_frames: LEAD_FRAMES, fps: 60)
      pos = speaking_portion_start(regions, portion)
      target = pos * duration + (lead_frames.to_f / fps)
      target = 0.0 if target < 0.0
      target = duration if target > duration
      target
    end

    # Is `pos` (normalized 0..1) inside the padding zone of the given
    # speaking portion? Padding zone = [start, start + padding/duration].
    def self.in_padding_zone?(regions, pos, portion, duration,
                              padding: PADDING_SECONDS)
      return false if duration <= 0.0
      pad_norm = padding / duration
      start_pos = speaking_portion_start(regions, portion)
      pos >= start_pos && pos < start_pos + pad_norm
    end

    # ------------------------------------------------------------------
    # Auto-pause FSM (pure — no side effects, testable without raylib/ECS)
    #
    # Ported from ../source/src/study.c study_auto_pause_check
    # ------------------------------------------------------------------
    #
    # Given the current playback position, silence regions, and hold-state
    # flags, returns a decision hash with the imperative actions to take.
    #
    # Inputs:
    #   current_time   — playback position in seconds
    #   duration       — total audio duration in seconds
    #   silence_regions — Array of {start:, end:} (normalized, padded)
    #   study_mode:    — bool, is study mode active?
    #   playing:       — bool, is audio currently playing?
    #   was_in_silence:— bool, previous frame's silence state
    #   last_silence_idx: — int, index of last silence region we were in
    #   smart_play_held:   — bool, is smart-play key held (suppress auto-pause)?
    #   space_held:        — bool, is space key held (suppress auto-pause)?
    #
    # Returns nil if no action possible (study_mode off, not playing,
    #   or duration <= 0).
    # Otherwise returns:
    #   { pause: bool, seek_target: Float|nil,
    #     was_in_silence: bool, last_silence_idx: int }
    #
    # When pause is true, the caller MUST:
    #   1. Pause the audio stream
    #   2. Seek to seek_target
    #   3. Set current_time = seek_target
    #   4. Set playing = false + skip_auto_update = 3
    #   5. Update was_in_silence / last_silence_idx from the decision
    #
    # When pause is false (override held, or no state change), the caller
    # still updates was_in_silence / last_silence_idx tracking.
    def self.auto_pause_check(current_time, duration, silence_regions,
                               study_mode:, playing:, was_in_silence:,
                               last_silence_idx:,
                               smart_play_held: false, space_held: false)
      return nil unless study_mode
      return nil unless playing
      return nil if duration <= 0.0

      pos = current_time / duration
      sil_idx = find_silence_at(silence_regions, pos)
      now_in_silence = sil_idx >= 0

      if smart_play_held || space_held
        # Override: track silence state but DO NOT auto-pause.
        return {
          pause: false,
          seek_target: nil,
          was_in_silence: now_in_silence,
          last_silence_idx: now_in_silence ? sil_idx : last_silence_idx,
        }
      end

      if now_in_silence && !was_in_silence
        # Just entered a silence region.
        # Action: pause and seek to start of NEXT speaking portion.
        target = portion_seek_target(duration, silence_regions, sil_idx + 1)
        return {
          pause: true,
          seek_target: target,
          was_in_silence: true,
          last_silence_idx: sil_idx,
        }
      elsif !now_in_silence && was_in_silence
        # Just exited a silence region (entered a speaking portion).
        # Action: pause and land at start of CURRENT speaking portion.
        portion_idx = current_speaking_portion(silence_regions, pos)
        target = portion_seek_target(duration, silence_regions, portion_idx)
        return {
          pause: true,
          seek_target: target,
          was_in_silence: false,
          last_silence_idx: last_silence_idx,
        }
      end

      # No boundary crossing — just track current state.
      {
        pause: false,
        seek_target: nil,
        was_in_silence: now_in_silence,
        last_silence_idx: now_in_silence ? sil_idx : last_silence_idx,
      }
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
    #   V / B          — prev/next speaking portion
    #   ESC            — quit
    #
    # Phase 4 adds: SMART_PLAY hold override

    SEEK_SMALL   = 5.0    # seconds: LEFT / RIGHT
    SEEK_LARGE   = 15.0   # seconds: UP / DOWN
    SEEK_PCT_STEP = 0.10  # 10%: J / L

    def self.build_system(world, player_entity, runtime, playback_state, study_state)
      world.system("Input", with: [], phase: Flecs::PRE_UPDATE) do
        pb = player_entity.get(playback_state)
        next unless pb

        duration = runtime.audio.duration

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

        # --- Portion navigation: V (prev) / B (next) ---
        regions = runtime.silence_regions
        if regions && regions.length >= 0 && duration > 0
          if Rl.key_pressed?(:v)
            # Previous portion
            pos_norm = Core.time_to_ratio(pb[:current_time], duration)
            current = Core.current_speaking_portion(regions, pos_norm)
            prev_portion = current - 1
            prev_portion = 0 if prev_portion < 0
            target = Core.portion_seek_target(duration, regions, prev_portion)
            pb[:seek_target] = target
            pb[:seek_pending] = true
            player_entity.set(playback_state, pb)
          elsif Rl.key_pressed?(:b)
            # Next portion
            pos_norm = Core.time_to_ratio(pb[:current_time], duration)
            current = Core.current_speaking_portion(regions, pos_norm)
            total = Core.total_speaking_portions(regions)
            next_portion = current + 1
            next_portion = total - 1 if next_portion >= total
            target = Core.portion_seek_target(duration, regions, next_portion)
            pb[:seek_target] = target
            pb[:seek_pending] = true
            player_entity.set(playback_state, pb)
          end
        end

        # --- Study mode toggle: M key ---
        if Rl.key_pressed?(:m)
          ss_current = player_entity.get(study_state)
          if ss_current
            ss_current[:study_mode] = !ss_current[:study_mode]
            player_entity.set(study_state, ss_current)
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

          # --- Phase 3: Silence detection via C scanner ---
          # StudyAudio.scan_silence does the peak scan in C (avoids building
          # a Ruby array of millions of float samples) and returns raw
          # normalized silence regions as [[start, end], ...].
          # We then pad them with the pure-Ruby pad_silence_regions.
          begin
            raw_pairs = StudyAudio.scan_silence(path,
              StudyPlayer::Core::SILENCE_THRESHOLD,
              StudyPlayer::Core::SILENCE_MIN_DURATION)
            if raw_pairs && raw_pairs.length > 0
              # Convert [[s,e],...] to [{start:, end:}, ...]
              raw_regions = []
              raw_pairs.each do |pair|
                raw_regions << { start: pair[0].to_f, end: pair[1].to_f }
              end
              regions = StudyPlayer::Core.pad_silence_regions(
                raw_regions, duration)
              runtime.silence_regions = regions
              runtime.raw_silence_regions = raw_regions
              runtime.analysis_done = true
            else
              runtime.silence_regions = []
              runtime.analysis_done = true
            end
          rescue => e
            begin
              Log.warn("Silence detection failed: #{e.message}") if defined?(Log)
            rescue
            end
            runtime.silence_regions = []
            runtime.analysis_done = false
          end
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
# System: StudySystem — Auto-pause FSM (imperative shell)
#
# Runs the pure Core.auto_pause_check FSM every frame during ON_UPDATE
# (after UpdateSystem). Applies pause/seek decisions to the audio engine.
#
# See: notes/study-player-rewrite-plan.md §3, §8
# Ported from: ../source/src/study.c study_auto_pause_check
# =============================================================================

module StudyPlayer
  class StudySystem
    def self.build(world, player_entity, runtime, playback_state, study_state)
      world.system("Study", with: [], phase: Flecs::ON_UPDATE) do
        pb = player_entity.get(playback_state)
        ss = player_entity.get(study_state)
        next unless pb && ss && pb[:loaded]

        regions = runtime.silence_regions
        next unless regions && regions.length >= 0

        # Resolve held-key overrides on this frame
        smart_held = Rl.key_down?(:s) || (runtime.ui && runtime.ui.smart_play_held?)
        space_held = Rl.key_down?(:space)

        # Update smart_play_held in the component (for UI display)
        if ss[:smart_play_held] != smart_held
          ss[:smart_play_held] = smart_held
          player_entity.set(study_state, ss)
        end

        duration = runtime.audio.duration

        decision = Core.auto_pause_check(
          pb[:current_time],
          duration,
          regions,
          study_mode: ss[:study_mode],
          playing: pb[:playing],
          was_in_silence: ss[:was_in_silence],
          last_silence_idx: ss[:last_silence_idx],
          smart_play_held: smart_held,
          space_held: space_held,
        )

        next unless decision

        # Always update silence tracking state from decision
        ss[:was_in_silence]   = decision[:was_in_silence]
        ss[:last_silence_idx] = decision[:last_silence_idx]
        player_entity.set(study_state, ss)

        # Apply pause + seek if the decision demands it
        if decision[:pause] && decision[:seek_target]
          target = decision[:seek_target]
          runtime.audio.pause
          runtime.audio.seek(target)
          pb[:current_time]     = target
          pb[:playing]          = false
          pb[:skip_auto_update] = 3  # Same cooldown as manual seek
          player_entity.set(playback_state, pb)
        end
      end
    end
  end
end

# =============================================================================
# Class: UI — RmlUi wrapper (Phase 5: full RmlUi player UI)
#
# Creates the Rml::Context, data model, loads the document, and provides
# per-frame sync from flecs state to the RmlUi data model.
#
# The data model is bound by name "player" in both the RML (data-model="player")
# and here. Events from RML data-event-* attributes call back into this class,
# which mutates flecs component state (seek_target, playing, study_mode, etc.).
#
# See: notes/study-player-rewrite-plan.md §6 (RmlUi UI structure)
#      docs/API_SPEC_RMLUI.md (RmlUi API)
#      .agents/knowledge/rmlui-binding.md (known quirks: left-not-right, FBO size)
# =============================================================================

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

    def smart_play_held?
      @smart_play_mouse_held
    end

    def sync
      @model.dirty_all

      # Update progress bar fill width directly (data-style can't handle
      # "width: {{var}}" syntax — it parses the property name as a variable).
      fill_el = @doc.element("progress-bar-fill")
      if fill_el
        pb = @player_ent.get(@comps[:playback_state])
        af = @player_ent.get(@comps[:audio_file])
        if pb && af[:duration] > 0
          ratio = StudyPlayer::Core.time_to_ratio(pb[:current_time], af[:duration])
          fill_el.set_property("width", "#{(ratio * 100.0).round(1)}%")
        end
      end
    end

    def process_input
      @context.process_input
    end

    def render
      @context.update
      @context.render
    end

    private

    def build_model
      ctx = @context
      af_c = @comps[:audio_file]
      pb_c = @comps[:playback_state]
      ss_c = @comps[:study_state]
      pe   = @player_ent
      rt   = @runtime

      ctx.data_model("player") do |m|
        # -- One-way computed bindings --
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

# =============================================================================
# Composition Root — init, components, systems, main loop
# =============================================================================

module StudyPlayer
  SCREEN_W = 1280
  SCREEN_H = 720

  # Runtime: owns non-serializable handles (Rl::Music) and the flecs world.
  class Runtime
    attr_accessor :world, :player_entity, :audio, :components, :ui
    attr_accessor :silence_regions, :raw_silence_regions, :analysis_done
    def initialize(world:, player_entity:, audio:, components:)
      @world = world
      @player_entity = player_entity
      @audio = audio
      @components = components
      @ui = nil
      @silence_regions = []
      @raw_silence_regions = []
      @analysis_done = false
    end
  end

  def self.run
    Rl.init_window(SCREEN_W, SCREEN_H, "Study Player")
    Rl.target_fps = 60
    Rl.init_audio_device
    Rml.init

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

    # --- RmlUi UI ---
    ui = UI.new(runtime, comps)
    runtime.ui = ui

    # --- Register systems ---
    LoadSystem.build(world, player_entity, runtime, af, pb, nl)
    SeekSystem.build(world, player_entity, runtime, pb)
    InputAdapter.build_system(world, player_entity, runtime, pb, ss)
    UpdateSystem.build(world, player_entity, runtime, pb)
    StudySystem.build(world, player_entity, runtime, pb, ss)

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

    # --- Main loop (RmlUi rendering) ---
    Rl.while_window_open do
      # Process RmlUi input (mouse clicks, text) before ECS systems so
      # UI events fire and update flecs state this frame.
      ui.process_input

      dt = Rl.frame_time

      # Check for quit
      if Rl.key_pressed?(:escape)
        Rl.close_window
        break
      end

      # Run ECS systems (keyboard input, seek, update, study)
      world.progress(dt)

      # Sync UI data model from updated flecs state
      ui.sync

      # Read back two-way study_mode value from the checkbox
      ss_current = player_entity.get(ss)
      model_study = ui.model[:study_mode]
      if ss_current && ss_current[:study_mode] != model_study
        ss_current[:study_mode] = model_study
        player_entity.set(ss, ss_current)
      end

      # Render: RmlUi draws on top of the deep-slate background
      Rl.draw(clear_color: Rl::Color.new(26, 26, 46, 255)) do
        ui.render
      end
    end

    # --- Shutdown ---
    audio.unload if audio.loaded?
    Rl.close_audio_device
  end
end

StudyPlayer.run

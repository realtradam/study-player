# Study Player — Pure domain logic (no side effects).
#
# All functions are side-effect-free: no raylib, no flecs, no I/O.
# Testable without the engine.
#
# Ported from: ../source/src/study.h + study.c
# See: notes/study-player-rewrite-plan.md §8 (pure core API sketch)

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
    #
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
    #
    # This is PURE: no raylib, no I/O, no side effects. Pass in the samples
    # and get silence regions back.
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
        (i...range_end).each do |j|
          v = samples[j]
          v = -v if v < 0
          peak = v if v > peak
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
        # else: collapsed → drop it
      end

      result
    end

    # Full analysis pipeline: detect raw gaps, then pad them.
    # Combines detect_silence + pad_silence_regions into one call.
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
    # During silence, returns the portion that just ended (the previous
    # speaking portion), matching the original C behavior.
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
    # Lands `lead_frames` render frames into the padding zone (~33ms at 60fps),
    # matching the original C behavior (portion_seek_target).
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
    # Returns nil if no action possible (study_mode off, not playing,
    # or duration <= 0).
    # Otherwise returns:
    #   { pause: bool, seek_target: Float|nil,
    #     was_in_silence: bool, last_silence_idx: int }
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
        return {
          pause: false,
          seek_target: nil,
          was_in_silence: now_in_silence,
          last_silence_idx: now_in_silence ? sil_idx : last_silence_idx,
        }
      end

      if now_in_silence && !was_in_silence
        target = portion_seek_target(duration, silence_regions, sil_idx + 1)
        return {
          pause: true,
          seek_target: target,
          was_in_silence: true,
          last_silence_idx: sil_idx,
        }
      elsif !now_in_silence && was_in_silence
        portion_idx = current_speaking_portion(silence_regions, pos)
        target = portion_seek_target(duration, silence_regions, portion_idx)
        return {
          pause: true,
          seek_target: target,
          was_in_silence: false,
          last_silence_idx: last_silence_idx,
        }
      end

      {
        pause: false,
        seek_target: nil,
        was_in_silence: now_in_silence,
        last_silence_idx: now_in_silence ? sil_idx : last_silence_idx,
      }
    end
  end
end

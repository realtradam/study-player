# Study Player — Pure domain logic (no side effects).
#
# All functions are side-effect-free: no raylib, no flecs, no I/O.
# Testable without the engine.
#
# See: notes/study-player-rewrite-plan.md §8 (pure core API sketch)

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

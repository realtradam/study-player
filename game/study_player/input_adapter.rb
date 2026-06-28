# Study Player — Input adapter.
#
# Reads raylib keyboard input and translates it into flecs component
# mutations (seek intents, play/pause toggles, smart-play flags).
#
# Registered as a PRE_UPDATE system so intents are available before
# the seek/update systems run in ON_UPDATE.
#
# See: notes/study-player-rewrite-plan.md §7 (non-blocking seek design)

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
    # Phase 4 adds:  M (study mode toggle), S (smart play hold), V/B (portion nav)

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

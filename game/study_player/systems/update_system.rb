# Study Player — Update system (ON_UPDATE).
#
# Every frame:
#   1. Calls Rl.update_music_stream (pumps the audio buffer).
#   2. Manages current_time: while skip_auto_update > 0, decrements it
#      without sampling the audio engine; otherwise samples via
#      Rl.get_music_time_played. This implements the non-blocking seek
#      cooldown.
#   3. Detects end-of-track (current_time >= duration) and auto-pauses.
#
# See: notes/study-player-rewrite-plan.md §7 (non-blocking seek design)

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

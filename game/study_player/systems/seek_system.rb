# Study Player — Seek system (PRE_UPDATE).
#
# Applies a pending seek intent:
#   1. Calls Rl.seek_music_stream to the target position.
#   2. Sets current_time = seek_target (instant visual update).
#   3. Sets skip_auto_update = N to implement non-blocking seek cooldown.
#   4. Clears seek_pending.
#
# Running in PRE_UPDATE means the subsequent UpdateSystem (ON_UPDATE)
# sees the already-applied seek and honours the cooldown counter.
#
# See: notes/study-player-rewrite-plan.md §7 (non-blocking seek design)

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

# Study Player — Load system.
#
# Reacts to entities with the NeedsLoad tag. Calls AudioAdapter.load,
# then sets the PlaybackState component (loaded, playing, duration,
# current_time=0).
#
# Registered as PRE_UPDATE so other systems in ON_UPDATE see the new state
# in the same frame.
#
# See: notes/study-player-rewrite-plan.md §5 (audio loading from argv)

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

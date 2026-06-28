# Study Player — Flecs component declarations.
#
# Components are real C structs declared at runtime via the flecs meta/reflection
# addon. Values are serialized as Ruby Hashes between C memory and Ruby.
#
# See: notes/study-player-rewrite-plan.md §3 (flecs component/state model)

module StudyPlayer
  # Declare components on a Flecs::World. Returns a Hash of component handles.
  def self.declare_components(world)
    {
      audio_file:     world.struct("AudioFile",     "{string path; float duration;}"),
      playback_state: world.struct("PlaybackState", "{bool loaded; bool playing; float current_time; int skip_auto_update; bool seek_pending; float seek_target;}"),
      study_state:    world.struct("StudyState",    "{bool study_mode; bool was_in_silence; int last_silence_idx; bool smart_play_held;}"),
      layout_dirty:   world.struct("LayoutDirty",   "{bool value;}"),
      needs_load:     world.tag("NeedsLoad"),
    }
  end
end

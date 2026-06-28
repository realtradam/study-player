# Study Player — Audio adapter (imperative shell).
#
# Wraps Rl::Music (LoadMusicStream / UnloadMusicStream / etc.) in a thin
# class that owns the handle and exposes play/pause/seek/update.
#
# The music handle is NOT stored in a flecs component (Ruby objects can't
# live in C struct components). It is owned by this adapter and held in
# the Runtime object.
#
# See: notes/study-player-rewrite-plan.md §5 (audio loading)

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

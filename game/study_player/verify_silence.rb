# Verify silence detection on a real audio file (self-contained, headless).
# Usage: ./zig-out/bin/game game/study_player/verify_silence.rb <audio_file>

# ── Pure Core module (inlined for mruby) ──

module StudyPlayer
  module Core
    SILENCE_THRESHOLD   = 0.015
    SILENCE_MIN_DURATION = 0.75
    PADDING_SECONDS     = 0.25
    CHUNK_SECONDS       = 0.01
    LEAD_FRAMES         = 2

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

      if in_silence
        len = total_frames - silence_start
        if len >= min_frames
          regions << { start: silence_start.to_f / total_frames, end: 1.0 }
        end
      end

      regions
    end

    def self.pad_silence_regions(regions, duration, padding: PADDING_SECONDS)
      return [] if duration <= 0.0
      return regions.dup if regions.empty?
      pad_norm = padding / duration
      result = []
      regions.each do |r|
        s = r[:start] + pad_norm
        e = r[:end]   - pad_norm
        result << { start: s, end: e } if s < e
      end
      result
    end

    def self.total_speaking_portions(regions)
      regions.length + 1
    end
  end
end

# ── Main ──

path = ARGV[0]
unless path && File.exist?(path)
  puts "Usage: game verify_silence.rb <audio_file>"
  exit 1
end

Rl.set_trace_log_level(4)  # suppress INFO spam
Rl.init_window(100, 100, "verify")
Rl.set_window_state(Rl::FLAG_WINDOW_HIDDEN)
Rl.init_audio_device

begin
  puts "Loading: #{path}"
  result = StudyAudio.load_wave_samples(path)

  if result.nil? || result.length != 2
    puts "ERROR: load_wave_samples failed"
    exit 1
  end

  sample_rate = result[0].to_i
  samples     = result[1]
  duration    = samples.length.to_f / sample_rate

  puts "Rate: #{sample_rate} Hz  Frames: #{samples.length}  Duration: #{duration.round(1)}s"

  raw = StudyPlayer::Core.detect_silence(samples, sample_rate)
  padded = StudyPlayer::Core.pad_silence_regions(raw, duration)
  portions = StudyPlayer::Core.total_speaking_portions(padded)

  puts "Raw silences: #{raw.length}  Padded: #{padded.length}  Portions: #{portions}"

  padded.first(5).each_with_index do |r, i|
    ss = r[:start] * duration
    es = r[:end] * duration
    puts "  [#{i}] #{ss.round(1)}s – #{es.round(1)}s (#{(es-ss).round(1)}s)"
  end
  puts "  ..." if padded.length > 5

  puts "OK: #{padded.length} silences, #{portions} portions"
rescue => e
  puts "FAIL: #{e.class}: #{e.message}"
  exit 1
ensure
  Rl.close_audio_device
  Rl.close_window
end

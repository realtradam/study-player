# Quick verification of scan_silence C function with a small audio file.
# Self-contained for mruby (no require).

path = ARGV[0]
unless path && File.exist?(path)
  puts "Usage: game verify_scan.rb <audio_file>"
  exit 1
end

Rl.set_trace_log_level(4)
Rl.init_window(100, 100, "vfy")
Rl.set_window_state(Rl::FLAG_WINDOW_HIDDEN)
Rl.init_audio_device

begin
  puts "File: #{path}"
  raw = StudyAudio.scan_silence(path, 0.015, 0.75)
  puts "Raw silence regions: #{raw.length}"
  raw.first(5).each_with_index do |r, i|
    puts "  [#{i}] #{r[0].round(4)} – #{r[1].round(4)}"
  end
  puts "  ..." if raw.length > 5
  puts "OK"
rescue => e
  puts "FAIL: #{e.class}: #{e.message}"
ensure
  Rl.close_audio_device
  Rl.close_window
end

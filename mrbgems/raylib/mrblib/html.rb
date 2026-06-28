module Jamstack
  module HTML
    class << self
      def scale=(mode)
        mode = mode.to_sym if mode.is_a?(String)
        raise ArgumentError, "scale must be :stretch or :native" unless [:stretch, :native].include?(mode)
        Jamstack.eval_js("jamstackSetSize(\"#{mode}\")")
        @scale = mode
      end

      def scale
        @scale || :stretch
      end

      def render=(mode)
        mode = mode.to_sym if mode.is_a?(String)
        raise ArgumentError, "render must be :auto, :pixelated, or :crisp_edges" unless [:auto, :pixelated, :crisp_edges].include?(mode)
        js_mode = mode == :crisp_edges ? "crisp-edges" : mode.to_s
        Jamstack.eval_js("jamstackSetRendering(\"#{js_mode}\")")
        @render = mode
      end

      def render
        @render || :auto
      end

      def toggle_fullscreen
        Jamstack.eval_js("if(document.fullscreenElement){document.exitFullscreen()}else{document.documentElement.requestFullscreen()}")
      end

      def title=(t)
        Jamstack.eval_js("document.title=#{t.to_s.inspect}")
      end
    end
  end

  def self.fonttest
    puts "=== Font Test ==="
    puts ""
    puts "--- ASCII ---"
    puts "abcdefghijklmnopqrstuvwxyz"
    puts "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
    puts "0123456789 !@#$%^&*()_+-=[]{}|;:',.<>?/`~"
    puts ""
    puts "--- Box Drawing ---"
    puts "+--+--+--+"
    puts "|  |  |  |"
    puts "+--+--+--+"
    puts ""
    puts "--- Arrows ---"
    puts "<- -> ^ v"
    puts ""
    puts "--- Nerd Font Icons ---"
    puts "Powerline: \uE0B0 \uE0B2 \uE0B1 \uE0B3"
    puts "Git:       \uE0A0 \uE0A2 \uE0A3"
    puts "Misc:      \uF004 \uF005 \uF00C \uF00D \uF013 \uF017"
    puts "OS:        \uF179 \uF17C \uE70F"
    puts "Devicons:  \uE739 \uE74E \uE73C \uE7A8"
    puts ""
    puts "--- Standard Emoji ---"
    puts "Faces:     \U0001F602 \U0001F923 \U0001F604 \U0001F60D \U0001F622"
    puts "Hands:     \U0001F44D \U0001F44E \U0001F44C \U0001F450"
    puts "Objects:   \U0001F525 \U0001F4A5 \U0001F4A9 \U0001F389 \U0001F680"
    puts "Animals:   \U0001F431 \U0001F436 \U0001F98A \U0001F414"
    puts ""
    puts "--- Long line (wrapping test) ---"
    puts "The quick brown fox jumps over the lazy dog. " * 4
    puts ""
    puts "--- Scroll test (30 lines) ---"
    30.times do |i|
      puts "Line #{i + 1}: The quick brown fox jumps over the lazy dog 1234567890"
    end
    puts ""
    puts "=== End of Font Test ==="
    "done"
  end
end

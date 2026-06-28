# Study Player — config persistence (Phase 6).
#
# Loads/saves a key=value INI file (study-player.cfg) in the current working
# directory. Format matches the original ../source/src/config.c INI style so
# existing config files are forward-compatible.
#
# Persisted settings (meaningful for the RmlUi UI):
#   window_width, window_height  — Rl.init_window size
#   study_mode_default           — whether study mode starts ON
#   volume                       — 0.0 .. 1.0
#   last_audio_path              — last file loaded (for quick reload)
#   font_scale                   — applied to the body element
#
# Plus all original UILayout keys mapped to RmlUi element properties
# (see Layout module for the mapping).
#
# See: notes/study-player-rewrite-plan.md §9 (layout persistence)
#      ../source/src/config.c (original INI loader)

module StudyPlayer
  module Config
    CFG_FILE = "study-player.cfg".freeze

    # Default values. Keys are symbols (Ruby); saved as strings (INI).
    DEFAULTS = {
      window_width:        1280,
      window_height:       720,
      study_mode_default:  false,
      volume:              1.0,
      last_audio_path:     "",
      font_scale:          1.0,
      # Original UILayout keys (will be mapped to RmlUi element properties
      # by Layout.apply). These are RESERVED for manual override; the default
      # RCSS positions are sufficient so we leave them nil/comment here.
    }.freeze

    # ------------------------------------------------------------------
    # Public API
    # ------------------------------------------------------------------

    # Load config from cwd. Returns a Hash with Symbol keys.
    # Missing / unreadable file → returns DEFAULTS.dup.
    def self.load
      cfg = DEFAULTS.dup
      path = config_path
      return cfg unless File.exist?(path)

      begin
        File.open(path, "r") do |f|
          f.each_line do |line|
            line = line.strip
            next if line.empty? || line.start_with?("#")

            key, val = line.split("=", 2)
            next unless key && val

            key_sym = key.strip.to_sym
            val_str = val.strip

            # Parse value type based on key context
            cfg[key_sym] = parse_value(key_sym, val_str)
          end
        end
      rescue => e
        # Unreadable file — stick with defaults
      end

      cfg
    end

    # Save settings hash to config file. Returns true on success.
    def self.save(settings)
      begin
        File.open(config_path, "w") do |f|
          f.puts "# Study Player config"
          f.puts "# Generated #{Time.now}" if respond_to?(:Time)
          settings.each do |key, val|
            val_s = format_value(val)
            f.puts "#{key}=#{val_s}"
          end
        end
        true
      rescue => e
        false
      end
    end

    # Return the full path to the config file.
    def self.config_path
      File.expand_path(CFG_FILE)
    end

    # ------------------------------------------------------------------
    # Value parsing / formatting
    # ------------------------------------------------------------------

    def self.parse_value(key, str)
      case key
      when :window_width, :window_height
        str.to_i
      when :volume, :font_scale
        str.to_f
      when :study_mode_default
        str == "true" || str == "1"
      else
        # For layout keys (numeric positions), return float
        f = str.to_f
        (f.to_i == f) ? f.to_i : f
      end
    end

    def self.format_value(val)
      case val
      when Float
        # Format with up to 2 decimal places, trim trailing zeros
        s = format("%.2f", val)
        s = s.sub(/\.?0+$/, "")
        s
      when TrueClass
        "true"
      when FalseClass
        "false"
      when Integer
        val.to_s
      else
        val.to_s
      end
    end
  end
end

# Study Player — Phase 1 scaffold.
#
# Minimal entry stub that verifies the build and opens a window. It does not
# load audio, detect silence, or implement study mode; those are Phase 2+.
#
# Run:
#   ./zig-out/bin/game game/study_player/study_player.rb

Rl.init_window(1280, 720, "Study Player")
Rl.target_fps = 60

Rml.init
Rml.load_font("game/ui/LatoLatin-Regular.ttf")
Rml.load_font("game/ui/LatoLatin-Bold.ttf")

ui = Rml::Context.new("main")

bg  = Rl::Color.new(26, 26, 46, 255)
txt = Rl::Color.new(234, 234, 234, 255)
accent = Rl::Color.new(233, 69, 96, 255)

Rl.while_window_open do
  ui.process_input

  Rl.draw(clear_color: bg) do
    Rl.draw_text(text: "Study Player",
                 x: 1280 / 2 - 180, y: 300, font_size: 60, color: txt)
    Rl.draw_text(text: "Phase 1 scaffold — audio + study mode coming in next phases",
                 x: 1280 / 2 - 320, y: 380, font_size: 20, color: accent)
  end

  ui.update
  ui.render
end

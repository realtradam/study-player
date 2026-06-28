# raylib-jamstack: in-game REPL console demo (R6).
#
#   ./zig-out/bin/game game/console_demo.rb        (desktop)
#   (web: preloaded; runnable as /game/console_demo.rb)
#
# A simple scene with a moving "player" square. Press \ or ` to open the
# REPL console. Type Ruby expressions to inspect/modify game state live.
#
# Controls: A/D move left/right, SPACE score++, \ or ` toggle console, ESC quit

Rl.init_window(720, 720, "raylib-jamstack: REPL console")
Rl.target_fps = 60

Rml.init
Rml.load_font("game/ui/LatoLatin-Regular.ttf")
Rml.load_font("game/ui/LatoLatin-Bold.ttf")
Rml.load_font("game/ui/MononokiNerdFontMono-Regular.ttf")

ui = Rml::Context.new("main")

score = 0
player_x = 360
player_y = 360
player_color = Rl::SKYBLUE

console = Jamstack::Console.new(ui, binding: binding)
# Expose these locals to the HTML REPL (web/shell.html) and the agent bridge
# (bin/eval) so they can be read/written live, just like the in-game console.
Jamstack::Bridge.set_binding(binding)

Rl.while_window_open do
  console.update
  ui.process_input

  unless console.open?
    player_x -= 300 * Rl.frame_time if Rl.key_down?(:a) && player_x > 20
    player_x += 300 * Rl.frame_time if Rl.key_down?(:d) && player_x < 700
    score += 1 if Rl.key_pressed?(:space)
  end

  player_y = 360 + Math.sin(Rl.time * 2) * 20

  Rl.draw(clear_color: Rl::Color.new(30, 30, 46, 255)) do
    Rl.draw_text(text: "A/D move   SPACE score++   \\ open console",
                 x: 12, y: 12, font_size: 18, color: Rl::GRAY)
    Rl.draw_text(text: "score: #{score}",
                 x: 12, y: 38, font_size: 20, color: Rl::YELLOW)

    Rl.draw_rectangle(player_x.to_i - 20, player_y.to_i - 20, 40, 40, player_color)

    ui.update
    ui.render
  end
end

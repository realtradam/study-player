# raylib-jamstack: Raylib + MRuby + RmlUi with Ruby data binding.

Rl.init_window(720, 720, "raylib-jamstack: data binding")
Rl.target_fps = 60

Rml.init
Rml.load_font("game/ui/LatoLatin-Regular.ttf")
Rml.load_font("game/ui/LatoLatin-Bold.ttf")

ui = Rml::Context.new("main")

# --- game state ---
score = 0
hp = 3
x = 350

# --- data model: binds Ruby state to the RML view (must precede load_document) ---
model = ui.data_model("hud") do |m|
  m.bind(:score)     { score }
  m.bind(:hp)        { hp }
  m.bind(:bar_width) { "#{(hp / 3.0 * 100).to_i}%" }
  m.event(:reset)    { score = 0 }
end

ui.load_document("game/ui/hud.rml").show

Rl.while_window_open do
  ui.process_input

  score += 1
  hp -= 1 if Rl.key_pressed?(:h) && hp > 0
  x += 200 * Rl.frame_time if Rl.key_down?(:d)
  x -= 200 * Rl.frame_time if Rl.key_down?(:a)

  # tell the view what changed this frame
  model.dirty(:score, :hp, :bar_width)

  Rl.draw(clear_color: Rl::BLACK) do
    Rl.draw_text(text: "game layer: A/D move, H damage, click Reset",
                 x: 200, y: 410, font_size: 16, color: Rl::GRAY)
    Rl.draw_text(text: "@", x: x.to_i, y: 300, font_size: 40, color: Rl::RED)

    ui.update
    ui.render
  end
end

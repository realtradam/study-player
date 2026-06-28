# raylib-jamstack: touch controls demo (virtual joystick + buttons).
#
#   ./zig-out/bin/game game/touch_demo.rb        (desktop)
#   (web: preloaded; runnable as /game/touch_demo.rb)
#
# A movable character controlled by a virtual joystick (left) and action
# buttons (right). Works with mouse on desktop, touch on mobile/browser.
#
# Controls: joystick = move, A = jump, B = sprint

Rl.init_window(720, 720, "raylib-jamstack: touch controls")
Rl.target_fps = 60

tc = Jamstack::TouchControls.new(joystick_x: 100, joystick_y: 620, joystick_radius: 70)
tc.add_button(:jump, x: 620, y: 580, radius: 45, label: "A")
tc.add_button(:sprint, x: 620, y: 680, radius: 35, label: "B")

px = 360.0
py = 360.0
vy = 0.0
color = Rl::SKYBLUE
SPEED = 300
GRAVITY = 1200
JUMP = 500

Rl.while_window_open do
  tc.update

  j = tc.joystick
  px += j.x * SPEED * Rl.frame_time
  py += j.y * SPEED * Rl.frame_time * 0.5

  if tc.button_pressed?(:jump) && py > 600
    vy = -JUMP
  end

  vy += GRAVITY * Rl.frame_time
  py += vy * Rl.frame_time

  if py > 660
    py = 660
    vy = 0
  end

  px = [[px, 20].max, 700].min

  c = tc.button_down?(:sprint) ? Rl::GOLD : Rl::SKYBLUE

  Rl.draw(clear_color: Rl::Color.new(30, 30, 46, 255)) do
    Rl.draw_text(text: "Joystick: move   A: jump   B: sprint",
                 x: 12, y: 12, font_size: 16, color: Rl::GRAY)
    Rl.draw_text(text: "touches: #{Rl.get_touch_point_count}",
                 x: 12, y: 34, font_size: 14, color: Rl::DARKGRAY)

    Rl.draw_rectangle(px.to_i - 20, py.to_i - 20, 40, 40, c)

    Rl.draw_rectangle(0, 660, 720, 60, Rl::Color.new(50, 50, 60, 255))

    tc.draw
  end
end

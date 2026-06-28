module Jamstack
  class TouchControls
    attr_reader :joystick_vector

    def initialize(joystick_x: 100, joystick_y: nil, joystick_radius: 60)
      sw = Rl.screen_width
      sh = Rl.screen_height
      @jbx = joystick_x
      @jby = joystick_y || (sh - joystick_x)
      @jbr = joystick_radius
      @jknob_x = 0
      @jknob_y = 0
      @jvec = Rl::Vector2.new(0, 0)
      @jactive = false
      @jtouch_id = -1
      @buttons = []
    end

    def add_button(name, x:, y:, radius: 40, label: nil)
      @buttons << {
        name: name, x: x, y: y, r: radius,
        label: label || name.to_s.upcase,
        touch_id: -1, held: false, prev: false
      }
      self
    end

    def update
      count = Rl.get_touch_point_count
      ids = []
      count.times { |i| ids << [Rl.get_touch_point_id(i), Rl.get_touch_position(i)] }

      update_joystick(ids)
      update_buttons(ids)
    end

    def joystick
      @jvec
    end

    def button_down?(name)
      b = find_button(name)
      b && b[:held]
    end

    def button_pressed?(name)
      b = find_button(name)
      b && b[:held] && !b[:prev]
    end

    def draw
      draw_joystick
      @buttons.each { |b| draw_button(b) }
    end

    private

    def update_joystick(touches)
      if @jactive
        match = touches.find { |id, _| id == @jtouch_id }
        if match
          _, pos = match
          dx = pos.x - @jbx
          dy = pos.y - @jby
          dist = Math.sqrt(dx * dx + dy * dy)
          if dist > @jbr
            dx = dx * @jbr / dist
            dy = dy * @jbr / dist
          end
          @jknob_x = dx
          @jknob_y = dy
          @jvec = Rl::Vector2.new(dx / @jbr, dy / @jbr)
        else
          reset_joystick
        end
      else
        match = touches.find { |_, pos| dist(pos.x, pos.y, @jbx, @jby) <= @jbr }
        if match
          @jactive = true
          @jtouch_id = match[0]
        end
      end
    end

    def reset_joystick
      @jactive = false
      @jtouch_id = -1
      @jknob_x = 0
      @jknob_y = 0
      @jvec = Rl::Vector2.new(0, 0)
    end

    def update_buttons(touches)
      @buttons.each do |b|
        b[:prev] = b[:held]
        if b[:touch_id] >= 0
          if touches.any? { |id, _| id == b[:touch_id] }
            b[:held] = true
          else
            b[:held] = false
            b[:touch_id] = -1
          end
        elsif !b[:held]
          match = touches.find { |_, pos| dist(pos.x, pos.y, b[:x], b[:y]) <= b[:r] }
          if match
            b[:touch_id] = match[0]
            b[:held] = true
          end
        end
      end
    end

    def find_button(name)
      @buttons.find { |b| b[:name] == name }
    end

    def dist(x1, y1, x2, y2)
      dx = x1 - x2; dy = y1 - y2
      Math.sqrt(dx * dx + dy * dy)
    end

    def draw_joystick
      c_base = Rl::Color.new(255, 255, 255, 40)
      c_ring = Rl::Color.new(255, 255, 255, 120)
      c_knob = Rl::Color.new(200, 210, 240, 180)
      Rl.draw_circle(@jbx, @jby, @jbr, c_base)
      Rl.draw_circle_lines(@jbx, @jby, @jbr, c_ring)
      Rl.draw_circle(@jbx + @jknob_x, @jby + @jknob_y, @jbr / 3, c_knob)
    end

    def draw_button(b)
      alpha = b[:held] ? 200 : 60
      fill = Rl::Color.new(150, 200, 255, alpha)
      ring = Rl::Color.new(255, 255, 255, 120)
      Rl.draw_circle(b[:x], b[:y], b[:r], fill)
      Rl.draw_circle_lines(b[:x], b[:y], b[:r], ring)
      Rl.draw_text(text: b[:label], x: b[:x] - 6, y: b[:y] - 8,
                   font_size: 16, color: Rl::Color.new(255, 255, 255, 200))
    end
  end
end

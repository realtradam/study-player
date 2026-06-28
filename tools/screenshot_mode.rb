# tools/screenshot_mode.rb — OPTIONAL in-script screenshot helpers.
#
# The PRIMARY, generic capture path is the env hook in Rl.while_window_open
# (gated by JAMSTACK_SCREENSHOT=<path>) + the bin/screenshot wrapper. That works
# on ANY game script with zero changes — see tools/SCREENSHOT.md.
#
# This file is for the case where you want MANUAL control over WHEN the frame is
# captured: e.g. capture at a specific game-state event (after a physics step
# settles, when a shader parameter hits a value, N frames after input). Require
# it from your game script and call Jamstack::Screenshot.capture(path) inside
# your Rl.while_window_open block at the moment you choose:
#
#   require_relative "../tools/screenshot_mode"
#   ...
#   Rl.while_window_open do
#     ... draw ...
#     Jamstack::Screenshot.capture("/tmp/scene.png") if some_condition
#   end
#
# capture() is a no-op unless JAMSTACK_SCREENSHOT_MANUAL=1 is set, so it is safe
# to leave committed in a game script — it only fires when you opt in. This keeps
# the env hook (auto-exit) and manual capture from both running.
#
# NOTE: take_screenshot reads the framebuffer AFTER the current frame's drawing
# is complete, so call capture() at the END of your block (after Rl.draw {}).
# On desktop the PNG is written synchronously by raylib. Do NOT commit PNGs.

module Jamstack
  module Screenshot
    class << self
      # True only when manual screenshot mode is opted in via the env var.
      # Keeps committed `capture` calls inert in normal runs.
      def enabled? = !::Jamstack.getenv('JAMSTACK_SCREENSHOT_MANUAL').nil?

      # Write a pixel-exact PNG of the current framebuffer to +path+.
      # No-op unless JAMSTACK_SCREENSHOT_MANUAL=1. Returns true if written.
      def capture(path)
        return false unless enabled?
        ::Rl.take_screenshot(path)
        ::Jamstack::Log.info("screenshot(manual) -> #{path}") rescue nil
        true
      end

      # Count frames and capture once +path+ after +frames+ frames have elapsed
      # since the first call. Useful inside the loop: pass the same path each
      # frame; it fires exactly once then stops. Returns true on the capturing
      # frame, nil otherwise. No-op unless enabled?.
      def capture_after(frames, path)
        return nil unless enabled?
        @counters ||= {}
        n = (@counters[path] ||= 0) + 1
        @counters[path] = n
        if n == frames
          capture(path)
        else
          nil
        end
      end

      # Reset the per-path frame counter (e.g. to re-capture the same path).
      def reset(path = nil)
        if path
          @counters&.delete(path)
        else
          @counters = {}
        end
      end
    end
  end
end

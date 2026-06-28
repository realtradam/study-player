# Rule: eval/console/bridge commands run on the main thread

All Ruby `eval` — whether from the agent bridge (TCP/WS), the in-game console,
or hot-reload — runs on the **main thread** via the frame-polled command queue
(`Jamstack::Bridge.drain`, called inside `while_window_open` before the game
block). Never call `mrb_funcall` or `eval` from a socket callback, JS callback,
or any thread other than the main loop. The mruby VM is not thread-safe.

The in-game console (`Jamstack::Console`) calls `eval` directly (not through the
queue), but it's safe because `console.update` runs on the main thread, before
`ctx.process_input`. The console and the bridge can coexist.

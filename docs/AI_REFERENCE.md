# raylib-jamstack — complete API reference (for AI agents)

Single-file description of the **entire** Ruby (mruby) API of this stack:
raylib 6.0 + raymath + RmlUi 6.x + flecs 4 (ECS) + Jolt 5 (3D physics). Everything an agent needs to write correct
game code without reading the bindings source. Auto-generated from
`raylib_api.json` / `raymath_api.json` by `mrbgems/raylib/tools/gen_ai_reference.rb`.

## Conventions (read first)
- C `PascalCase` -> Ruby `snake_case`. `IsXxx(...)` -> `xxx?` predicate.
- All raylib structs are classes under `Rl::` with a **positional** constructor
  in field order and `obj.field` / `obj.field=` accessors (see Structs).
- Enum values and color/numeric `#define`s are constants under `Rl::`
  (e.g. `Rl::KEY_SPACE`, `Rl::MOUSE_BUTTON_LEFT`, `Rl::GOLD`, `Rl::PI`).
- Signatures below are `Rl.name(arg:Type, ...) -> ReturnType`. **No `-> ` means
  the call returns `nil`.** `Boolean` = true/false. Struct types are `Rl::X`.
- A struct passed where C takes a single `T*` is **in/out**: pass an `Rl::T`
  instance; the call may mutate it.
- String args accept `nil` (becomes C `NULL`), e.g.
  `Rl.load_shader_from_memory(nil, fs)` for the default vertex shader.
- Symbol keys work anywhere a keycode is expected via the input predicates:
  `:a`..`:z`, `:0`..`:9`, `:space :enter :escape :tab :backspace :up :down
  :left :right :left_shift :left_control` — or use `Rl::KEY_*` ints.
- There is no global state you must thread; raylib is a global singleton.

## Idiomatic helpers (defined in Ruby, not 1:1 C)
```ruby
Rl.while_window_open { ... }          # the ONLY main loop. web-safe (emscripten
                                      # main loop on web; `until close?` on desktop,
                                      # auto-calls close_window on desktop exit).
Rl.draw(clear_color: Rl::RAYWHITE) { ... }   # begin_drawing+clear+end_drawing (ensure)
Rl.mode_2d(camera) { ... }            # begin/end_mode2d            (exception-safe)
Rl.mode_3d(camera) { ... }            # begin/end_mode3d
Rl.texture_mode(render_texture) { ... }
Rl.blend_mode(mode) { ... }           # mode = Rl::BLEND_*
Rl.shader_mode(shader) { ... }
Rl.scissor_mode(x:, y:, width:, height:) { ... }
Rl.draw_text(text:, x:, y:, font_size:, color:)               # kwarg form
Rl.draw_texture_pro(texture:, source:, dest:, origin: Rl::Vector2.new(0,0),
                    rotation: 0, tint: Rl::WHITE)              # kwarg form
Rl.platform  # :web|:desktop ;  Rl.web? ;  Rl.desktop?
# aliases: Rl.target_fps= , Rl.master_volume= , Rl.frame_time, Rl.time, Rl.fps,
#          Rl.screen_width, Rl.screen_height, Rl.mouse_x, Rl.mouse_y,
#          Rl.mouse_position, Rl.mouse_wheel
```
NOTE: `draw_text` and `draw_texture_pro` are the keyword forms above (they
override the positional generated versions). All other calls are positional.

## Minimal program
```ruby
Rl.init_window(800, 450, "demo")
Rl.target_fps = 60
Rl.while_window_open do
  Rl.draw(clear_color: Rl::RAYWHITE) do
    Rl.draw_text(text: "hello", x: 20, y: 20, font_size: 20, color: Rl::DARKGRAY)
    Rl.draw_circle_v(Rl.mouse_position, 16, Rl::RED) if Rl.mouse_button_down?(Rl::MOUSE_BUTTON_LEFT)
  end
end
```

## raylib functions (by module)

### core
```ruby
Rl.init_window(width:Integer, height:Integer, title:String)  # Initialize window and OpenGL context
Rl.close_window  # Close window and unload OpenGL context
Rl.window_should_close -> Boolean  # Check if application should close (KEY_ESCAPE pressed or windows close icon clicked)
Rl.window_ready? -> Boolean  # Check if window has been initialized successfully
Rl.window_fullscreen? -> Boolean  # Check if window is currently fullscreen
Rl.window_hidden? -> Boolean  # Check if window is currently hidden
Rl.window_minimized? -> Boolean  # Check if window is currently minimized
Rl.window_maximized? -> Boolean  # Check if window is currently maximized
Rl.window_focused? -> Boolean  # Check if window is currently focused
Rl.window_resized? -> Boolean  # Check if window has been resized last frame
Rl.window_state?(flag:Integer) -> Boolean  # Check if one specific window flag is enabled
Rl.set_window_state(flags:Integer)  # Set window configuration state using flags
Rl.clear_window_state(flags:Integer)  # Clear window configuration state flags
Rl.toggle_fullscreen  # Toggle window state: fullscreen/windowed, resizes monitor to match window resolution
Rl.toggle_borderless_windowed  # Toggle window state: borderless windowed, resizes window to match monitor resolution
Rl.maximize_window  # Set window state: maximized, if resizable
Rl.minimize_window  # Set window state: minimized, if resizable
Rl.restore_window  # Restore window from being minimized/maximized
Rl.set_window_icon(image:Rl::Image)  # Set icon for window (single image, RGBA 32bit)
Rl.set_window_icons(images:Rl::Image, count:Integer)  # Set icon for window (multiple images, RGBA 32bit)
Rl.set_window_title(title:String)  # Set title for window
Rl.set_window_position(x:Integer, y:Integer)  # Set window position on screen
Rl.set_window_monitor(monitor:Integer)  # Set monitor for the current window
Rl.set_window_min_size(width:Integer, height:Integer)  # Set window minimum dimensions (for FLAG_WINDOW_RESIZABLE)
Rl.set_window_max_size(width:Integer, height:Integer)  # Set window maximum dimensions (for FLAG_WINDOW_RESIZABLE)
Rl.set_window_size(width:Integer, height:Integer)  # Set window dimensions
Rl.set_window_opacity(opacity:Float)  # Set window opacity [0.0f..1.0f]
Rl.set_window_focused  # Set window focused
Rl.get_screen_width -> Integer  # Get current screen width
Rl.get_screen_height -> Integer  # Get current screen height
Rl.get_render_width -> Integer  # Get current render width (it considers HiDPI)
Rl.get_render_height -> Integer  # Get current render height (it considers HiDPI)
Rl.get_monitor_count -> Integer  # Get number of connected monitors
Rl.get_current_monitor -> Integer  # Get current monitor where window is placed
Rl.get_monitor_position(monitor:Integer) -> Rl::Vector2  # Get specified monitor position
Rl.get_monitor_width(monitor:Integer) -> Integer  # Get specified monitor width (current video mode used by monitor)
Rl.get_monitor_height(monitor:Integer) -> Integer  # Get specified monitor height (current video mode used by monitor)
Rl.get_monitor_physical_width(monitor:Integer) -> Integer  # Get specified monitor physical width in millimetres
Rl.get_monitor_physical_height(monitor:Integer) -> Integer  # Get specified monitor physical height in millimetres
Rl.get_monitor_refresh_rate(monitor:Integer) -> Integer  # Get specified monitor refresh rate
Rl.get_window_position -> Rl::Vector2  # Get window position XY on monitor
Rl.get_window_scale_dpi -> Rl::Vector2  # Get window scale DPI factor
Rl.get_monitor_name(monitor:Integer) -> String  # Get the human-readable, UTF-8 encoded name of the specified monitor
Rl.set_clipboard_text(text:String)  # Set clipboard text content
Rl.get_clipboard_text -> String  # Get clipboard text content
Rl.enable_event_waiting  # Enable waiting for events on EndDrawing(), no automatic event polling
Rl.disable_event_waiting  # Disable waiting for events on EndDrawing(), automatic events polling
Rl.show_cursor  # Shows cursor
Rl.hide_cursor  # Hides cursor
Rl.cursor_hidden? -> Boolean  # Check if cursor is not visible
Rl.enable_cursor  # Enables cursor (unlock cursor)
Rl.disable_cursor  # Disables cursor (lock cursor)
Rl.cursor_on_screen? -> Boolean  # Check if cursor is on the screen
Rl.clear_background(color:Rl::Color)  # Set background color (framebuffer clear color)
Rl.begin_drawing  # Setup canvas (framebuffer) to start drawing
Rl.end_drawing  # End canvas drawing and swap buffers (double buffering)
Rl.begin_mode2d(camera:Rl::Camera2D)  # Begin 2D mode with custom camera (2D)
Rl.end_mode2d  # Ends 2D mode with custom camera
Rl.begin_mode3d(camera:Rl::Camera3D)  # Begin 3D mode with custom camera (3D)
Rl.end_mode3d  # Ends 3D mode and returns to default 2D orthographic mode
Rl.begin_texture_mode(target:Rl::RenderTexture)  # Begin drawing to render texture
Rl.end_texture_mode  # Ends drawing to render texture
Rl.begin_shader_mode(shader:Rl::Shader)  # Begin custom shader drawing
Rl.end_shader_mode  # End custom shader drawing (use default shader)
Rl.begin_blend_mode(mode:Integer)  # Begin blending mode (alpha, additive, multiplied, subtract, custom)
Rl.end_blend_mode  # End blending mode (reset to default: alpha blending)
Rl.begin_scissor_mode(x:Integer, y:Integer, width:Integer, height:Integer)  # Begin scissor mode (define screen area for following drawing)
Rl.end_scissor_mode  # End scissor mode
Rl.begin_vr_stereo_mode(config:Rl::VrStereoConfig)  # Begin stereo rendering (requires VR simulator)
Rl.end_vr_stereo_mode  # End stereo rendering (requires VR simulator)
Rl.load_vr_stereo_config(device:Rl::VrDeviceInfo) -> Rl::VrStereoConfig  # Load VR stereo config for VR simulator device parameters
Rl.unload_vr_stereo_config(config:Rl::VrStereoConfig)  # Unload VR stereo config
Rl.load_shader(vs_file_name:String, fs_file_name:String) -> Rl::Shader  # Load shader from files and bind default locations
Rl.load_shader_from_memory(vs_code:String, fs_code:String) -> Rl::Shader  # Load shader from code strings and bind default locations
Rl.shader_valid?(shader:Rl::Shader) -> Boolean  # Check if a shader is valid (loaded on GPU)
Rl.get_shader_location(shader:Rl::Shader, uniform_name:String) -> Integer  # Get shader uniform location
Rl.get_shader_location_attrib(shader:Rl::Shader, attrib_name:String) -> Integer  # Get shader attribute location
Rl.set_shader_value(shader:Rl::Shader, loc_index:Integer, value:Numeric|Array, uniform_type:Integer)  # value packed per SHADER_UNIFORM_* type
Rl.set_shader_value_v(shader:Rl::Shader, loc_index:Integer, value:Array, uniform_type:Integer, count:Integer)
Rl.set_shader_value_matrix(shader:Rl::Shader, loc_index:Integer, mat:Rl::Matrix)  # Set shader uniform value (matrix 4x4)
Rl.set_shader_value_texture(shader:Rl::Shader, loc_index:Integer, texture:Rl::Texture)  # Set shader uniform value and bind the texture (sampler2d)
Rl.unload_shader(shader:Rl::Shader)  # Unload shader from GPU memory (VRAM)
Rl.get_screen_to_world_ray(position:Rl::Vector2, camera:Rl::Camera3D) -> Rl::Ray  # Get a ray trace from screen position (i.e mouse)
Rl.get_screen_to_world_ray_ex(position:Rl::Vector2, camera:Rl::Camera3D, width:Integer, height:Integer) -> Rl::Ray  # Get a ray trace from screen position (i.e mouse) in a viewport
Rl.get_world_to_screen(position:Rl::Vector3, camera:Rl::Camera3D) -> Rl::Vector2  # Get the screen space position for a 3d world space position
Rl.get_world_to_screen_ex(position:Rl::Vector3, camera:Rl::Camera3D, width:Integer, height:Integer) -> Rl::Vector2  # Get size position for a 3d world space position
Rl.get_world_to_screen2d(position:Rl::Vector2, camera:Rl::Camera2D) -> Rl::Vector2  # Get the screen space position for a 2d camera world space position
Rl.get_screen_to_world2d(position:Rl::Vector2, camera:Rl::Camera2D) -> Rl::Vector2  # Get the world space position for a 2d camera screen space position
Rl.get_camera_matrix(camera:Rl::Camera3D) -> Rl::Matrix  # Get camera transform matrix (view matrix)
Rl.get_camera_matrix2d(camera:Rl::Camera2D) -> Rl::Matrix  # Get camera 2d transform matrix
Rl.set_target_fps(fps:Integer)  # Set target FPS (maximum)
Rl.get_frame_time -> Float  # Get time in seconds for last frame drawn (delta time)
Rl.get_time -> Float  # Get elapsed time in seconds since InitWindow()
Rl.get_fps -> Integer  # Get current FPS
Rl.swap_screen_buffer  # Swap back buffer with front buffer (screen drawing)
Rl.poll_input_events  # Register all input events
Rl.wait_time(seconds:Float)  # Wait for some time (halt program execution)
Rl.set_random_seed(seed:Integer)  # Set the seed for the random number generator
Rl.get_random_value(min:Integer, max:Integer) -> Integer  # Get a random value between min and max (both included)
Rl.take_screenshot(file_name:String)  # Takes a screenshot of current screen (filename extension defines format)
Rl.set_config_flags(flags:Integer)  # Setup init configuration flags (view FLAGS)
Rl.open_url(url:String)  # Open URL with default system browser (if available)
Rl.set_trace_log_level(log_level:Integer)  # Set the current threshold (minimum) log level
Rl.load_file_text(file_name:String) -> String  # Load text data from file (read), returns a '\0' terminated string
Rl.save_file_text(file_name:String, text:String) -> Boolean  # Save text data to file (write), string must be '\0' terminated, returns true on success
Rl.file_rename(file_name:String, file_rename:String) -> Integer  # Rename file (if exists)
Rl.file_remove(file_name:String) -> Integer  # Remove file (if exists)
Rl.file_copy(src_path:String, dst_path:String) -> Integer  # Copy file from one path to another, dstPath created if it doesn't exist
Rl.file_move(src_path:String, dst_path:String) -> Integer  # Move file from one directory to another, dstPath created if it doesn't exist
Rl.file_text_replace(file_name:String, search:String, replacement:String) -> Integer  # Replace text in an existing file
Rl.file_text_find_index(file_name:String, search:String) -> Integer  # Find text in existing file
Rl.file_exists(file_name:String) -> Boolean  # Check if file exists
Rl.directory_exists(dir_path:String) -> Boolean  # Check if a directory path exists
Rl.file_extension?(file_name:String, ext:String) -> Boolean  # Check file extension (recommended include point: .png, .wav)
Rl.get_file_length(file_name:String) -> Integer  # Get file length in bytes (NOTE: GetFileSize() conflicts with windows.h)
Rl.get_file_mod_time(file_name:String) -> Integer  # Get file modification time (last write time)
Rl.get_file_extension(file_name:String) -> String  # Get pointer to extension for a filename string (includes dot: '.png')
Rl.get_file_name(file_path:String) -> String  # Get pointer to filename for a path string
Rl.get_file_name_without_ext(file_path:String) -> String  # Get filename string without extension (uses static string)
Rl.get_directory_path(file_path:String) -> String  # Get full path for a given fileName with path (uses static string)
Rl.get_prev_directory_path(dir_path:String) -> String  # Get previous directory path for a given path (uses static string)
Rl.get_working_directory -> String  # Get current working directory (uses static string)
Rl.get_application_directory -> String  # Get the directory of the running application (uses static string)
Rl.make_directory(dir_path:String) -> Integer  # Create directories (including full path requested), returns 0 on success
Rl.change_directory(dir_path:String) -> Boolean  # Change working directory, return true on success
Rl.path_file?(path:String) -> Boolean  # Check if a given path is a file or a directory
Rl.file_name_valid?(file_name:String) -> Boolean  # Check if fileName is valid for the platform/OS
Rl.load_directory_files(dir_path:String) -> Rl::FilePathList  # Load directory filepaths, files and directories, no subdirs scan
Rl.load_directory_files_ex(base_path:String, filter:String, scan_subdirs:Boolean) -> Rl::FilePathList  # Load directory filepaths with extension filtering and subdir scan; some filters available: "*.*", "FILES*", "DIRS*"
Rl.unload_directory_files(files:Rl::FilePathList)  # Unload filepaths
Rl.file_dropped? -> Boolean  # Check if a file has been dropped into window
Rl.load_dropped_files -> Rl::FilePathList  # Load dropped filepaths
Rl.unload_dropped_files(files:Rl::FilePathList)  # Unload dropped filepaths
Rl.get_directory_file_count(dir_path:String) -> Integer  # Get the file count in a directory
Rl.get_directory_file_count_ex(base_path:String, filter:String, scan_subdirs:Boolean) -> Integer  # Get the file count in a directory with extension filtering and recursive directory scan. Use 'DIR' in the filter string to include directories in the result
Rl.load_automation_event_list(file_name:String) -> Rl::AutomationEventList  # Load automation events list from file, NULL for empty list, capacity = MAX_AUTOMATION_EVENTS
Rl.unload_automation_event_list(list:Rl::AutomationEventList)  # Unload automation events list from file
Rl.export_automation_event_list(list:Rl::AutomationEventList, file_name:String) -> Boolean  # Export automation events list as text file
Rl.set_automation_event_list(list:Rl::AutomationEventList)  # Set automation event list to record to
Rl.set_automation_event_base_frame(frame:Integer)  # Set automation event internal base frame to start recording
Rl.start_automation_event_recording  # Start recording automation events (AutomationEventList must be set)
Rl.stop_automation_event_recording  # Stop recording automation events
Rl.play_automation_event(event:Rl::AutomationEvent)  # Play a recorded automation event
Rl.key_pressed?(key:Integer) -> Boolean  # Check if a key has been pressed once
Rl.key_pressed_repeat?(key:Integer) -> Boolean  # Check if a key has been pressed again
Rl.key_down?(key:Integer) -> Boolean  # Check if a key is being pressed
Rl.key_released?(key:Integer) -> Boolean  # Check if a key has been released once
Rl.key_up?(key:Integer) -> Boolean  # Check if a key is NOT being pressed
Rl.get_key_pressed -> Integer  # Get key pressed (keycode), call it multiple times for keys queued, returns 0 when the queue is empty
Rl.get_char_pressed -> Integer  # Get char pressed (unicode), call it multiple times for chars queued, returns 0 when the queue is empty
Rl.get_key_name(key:Integer) -> String  # Get name of a QWERTY key on the current keyboard layout (eg returns string 'q' for KEY_A on an AZERTY keyboard)
Rl.set_exit_key(key:Integer)  # Set a custom key to exit program (default is ESC)
Rl.gamepad_available?(gamepad:Integer) -> Boolean  # Check if a gamepad is available
Rl.get_gamepad_name(gamepad:Integer) -> String  # Get gamepad internal name id
Rl.gamepad_button_pressed?(gamepad:Integer, button:Integer) -> Boolean  # Check if a gamepad button has been pressed once
Rl.gamepad_button_down?(gamepad:Integer, button:Integer) -> Boolean  # Check if a gamepad button is being pressed
Rl.gamepad_button_released?(gamepad:Integer, button:Integer) -> Boolean  # Check if a gamepad button has been released once
Rl.gamepad_button_up?(gamepad:Integer, button:Integer) -> Boolean  # Check if a gamepad button is NOT being pressed
Rl.get_gamepad_button_pressed -> Integer  # Get the last gamepad button pressed
Rl.get_gamepad_axis_count(gamepad:Integer) -> Integer  # Get axis count for a gamepad
Rl.get_gamepad_axis_movement(gamepad:Integer, axis:Integer) -> Float  # Get movement value for a gamepad axis
Rl.set_gamepad_mappings(mappings:String) -> Integer  # Set internal gamepad mappings (SDL_GameControllerDB)
Rl.set_gamepad_vibration(gamepad:Integer, left_motor:Float, right_motor:Float, duration:Float)  # Set gamepad vibration for both motors (duration in seconds)
Rl.mouse_button_pressed?(button:Integer) -> Boolean  # Check if a mouse button has been pressed once
Rl.mouse_button_down?(button:Integer) -> Boolean  # Check if a mouse button is being pressed
Rl.mouse_button_released?(button:Integer) -> Boolean  # Check if a mouse button has been released once
Rl.mouse_button_up?(button:Integer) -> Boolean  # Check if a mouse button is NOT being pressed
Rl.get_mouse_x -> Integer  # Get mouse position X
Rl.get_mouse_y -> Integer  # Get mouse position Y
Rl.get_mouse_position -> Rl::Vector2  # Get mouse position XY
Rl.get_mouse_delta -> Rl::Vector2  # Get mouse delta between frames
Rl.set_mouse_position(x:Integer, y:Integer)  # Set mouse position XY
Rl.set_mouse_offset(offset_x:Integer, offset_y:Integer)  # Set mouse offset
Rl.set_mouse_scale(scale_x:Float, scale_y:Float)  # Set mouse scaling
Rl.get_mouse_wheel_move -> Float  # Get mouse wheel movement for X or Y, whichever is larger
Rl.get_mouse_wheel_move_v -> Rl::Vector2  # Get mouse wheel movement for both X and Y
Rl.set_mouse_cursor(cursor:Integer)  # Set mouse cursor
Rl.get_touch_x -> Integer  # Get touch position X for touch point 0 (relative to screen size)
Rl.get_touch_y -> Integer  # Get touch position Y for touch point 0 (relative to screen size)
Rl.get_touch_position(index:Integer) -> Rl::Vector2  # Get touch position XY for a touch point index (relative to screen size)
Rl.get_touch_point_id(index:Integer) -> Integer  # Get touch point identifier for given index
Rl.get_touch_point_count -> Integer  # Get number of touch points
Rl.set_gestures_enabled(flags:Integer)  # Enable a set of gestures using flags
Rl.gesture_detected?(gesture:Integer) -> Boolean  # Check if a gesture have been detected
Rl.get_gesture_detected -> Integer  # Get latest detected gesture
Rl.get_gesture_hold_duration -> Float  # Get gesture hold time in seconds
Rl.get_gesture_drag_vector -> Rl::Vector2  # Get gesture drag vector
Rl.get_gesture_drag_angle -> Float  # Get gesture drag angle
Rl.get_gesture_pinch_vector -> Rl::Vector2  # Get gesture pinch delta
Rl.get_gesture_pinch_angle -> Float  # Get gesture pinch angle
Rl.update_camera(camera:Rl::Camera3D, mode:Integer)  # Update camera position for selected mode
Rl.update_camera_pro(camera:Rl::Camera3D, movement:Rl::Vector3, rotation:Rl::Vector3, zoom:Float)  # Update camera movement/rotation
```

### shapes
```ruby
Rl.set_shapes_texture(texture:Rl::Texture, source:Rl::Rectangle)  # Set texture and rectangle to be used on shapes drawing
Rl.get_shapes_texture -> Rl::Texture  # Get texture that is used for shapes drawing
Rl.get_shapes_texture_rectangle -> Rl::Rectangle  # Get texture source rectangle that is used for shapes drawing
Rl.draw_pixel(pos_x:Integer, pos_y:Integer, color:Rl::Color)  # Draw a pixel using geometry [Can be slow, use with care]
Rl.draw_pixel_v(position:Rl::Vector2, color:Rl::Color)  # Draw a pixel using geometry (Vector version) [Can be slow, use with care]
Rl.draw_line(start_pos_x:Integer, start_pos_y:Integer, end_pos_x:Integer, end_pos_y:Integer, color:Rl::Color)  # Draw a line
Rl.draw_line_v(start_pos:Rl::Vector2, end_pos:Rl::Vector2, color:Rl::Color)  # Draw a line (using gl lines)
Rl.draw_line_ex(start_pos:Rl::Vector2, end_pos:Rl::Vector2, thick:Float, color:Rl::Color)  # Draw a line (using triangles/quads)
Rl.draw_line_strip(points:Rl::Vector2, point_count:Integer, color:Rl::Color)  # Draw lines sequence (using gl lines)
Rl.draw_line_bezier(start_pos:Rl::Vector2, end_pos:Rl::Vector2, thick:Float, color:Rl::Color)  # Draw line segment cubic-bezier in-out interpolation
Rl.draw_line_dashed(start_pos:Rl::Vector2, end_pos:Rl::Vector2, dash_size:Integer, space_size:Integer, color:Rl::Color)  # Draw a dashed line
Rl.draw_circle(center_x:Integer, center_y:Integer, radius:Float, color:Rl::Color)  # Draw a color-filled circle
Rl.draw_circle_v(center:Rl::Vector2, radius:Float, color:Rl::Color)  # Draw a color-filled circle (Vector version)
Rl.draw_circle_gradient(center:Rl::Vector2, radius:Float, inner:Rl::Color, outer:Rl::Color)  # Draw a gradient-filled circle
Rl.draw_circle_sector(center:Rl::Vector2, radius:Float, start_angle:Float, end_angle:Float, segments:Integer, color:Rl::Color)  # Draw a piece of a circle
Rl.draw_circle_sector_lines(center:Rl::Vector2, radius:Float, start_angle:Float, end_angle:Float, segments:Integer, color:Rl::Color)  # Draw circle sector outline
Rl.draw_circle_lines(center_x:Integer, center_y:Integer, radius:Float, color:Rl::Color)  # Draw circle outline
Rl.draw_circle_lines_v(center:Rl::Vector2, radius:Float, color:Rl::Color)  # Draw circle outline (Vector version)
Rl.draw_ellipse(center_x:Integer, center_y:Integer, radius_h:Float, radius_v:Float, color:Rl::Color)  # Draw ellipse
Rl.draw_ellipse_v(center:Rl::Vector2, radius_h:Float, radius_v:Float, color:Rl::Color)  # Draw ellipse (Vector version)
Rl.draw_ellipse_lines(center_x:Integer, center_y:Integer, radius_h:Float, radius_v:Float, color:Rl::Color)  # Draw ellipse outline
Rl.draw_ellipse_lines_v(center:Rl::Vector2, radius_h:Float, radius_v:Float, color:Rl::Color)  # Draw ellipse outline (Vector version)
Rl.draw_ring(center:Rl::Vector2, inner_radius:Float, outer_radius:Float, start_angle:Float, end_angle:Float, segments:Integer, color:Rl::Color)  # Draw ring
Rl.draw_ring_lines(center:Rl::Vector2, inner_radius:Float, outer_radius:Float, start_angle:Float, end_angle:Float, segments:Integer, color:Rl::Color)  # Draw ring outline
Rl.draw_rectangle(pos_x:Integer, pos_y:Integer, width:Integer, height:Integer, color:Rl::Color)  # Draw a color-filled rectangle
Rl.draw_rectangle_v(position:Rl::Vector2, size:Rl::Vector2, color:Rl::Color)  # Draw a color-filled rectangle (Vector version)
Rl.draw_rectangle_rec(rec:Rl::Rectangle, color:Rl::Color)  # Draw a color-filled rectangle
Rl.draw_rectangle_pro(rec:Rl::Rectangle, origin:Rl::Vector2, rotation:Float, color:Rl::Color)  # Draw a color-filled rectangle with pro parameters
Rl.draw_rectangle_gradient_v(pos_x:Integer, pos_y:Integer, width:Integer, height:Integer, top:Rl::Color, bottom:Rl::Color)  # Draw a vertical-gradient-filled rectangle
Rl.draw_rectangle_gradient_h(pos_x:Integer, pos_y:Integer, width:Integer, height:Integer, left:Rl::Color, right:Rl::Color)  # Draw a horizontal-gradient-filled rectangle
Rl.draw_rectangle_gradient_ex(rec:Rl::Rectangle, top_left:Rl::Color, bottom_left:Rl::Color, bottom_right:Rl::Color, top_right:Rl::Color)  # Draw a gradient-filled rectangle with custom vertex colors
Rl.draw_rectangle_lines(pos_x:Integer, pos_y:Integer, width:Integer, height:Integer, color:Rl::Color)  # Draw rectangle outline
Rl.draw_rectangle_lines_ex(rec:Rl::Rectangle, line_thick:Float, color:Rl::Color)  # Draw rectangle outline with extended parameters
Rl.draw_rectangle_rounded(rec:Rl::Rectangle, roundness:Float, segments:Integer, color:Rl::Color)  # Draw rectangle with rounded edges
Rl.draw_rectangle_rounded_lines(rec:Rl::Rectangle, roundness:Float, segments:Integer, color:Rl::Color)  # Draw rectangle lines with rounded edges
Rl.draw_rectangle_rounded_lines_ex(rec:Rl::Rectangle, roundness:Float, segments:Integer, line_thick:Float, color:Rl::Color)  # Draw rectangle with rounded edges outline
Rl.draw_triangle(v1:Rl::Vector2, v2:Rl::Vector2, v3:Rl::Vector2, color:Rl::Color)  # Draw a color-filled triangle (vertex in counter-clockwise order!)
Rl.draw_triangle_lines(v1:Rl::Vector2, v2:Rl::Vector2, v3:Rl::Vector2, color:Rl::Color)  # Draw triangle outline (vertex in counter-clockwise order!)
Rl.draw_triangle_fan(points:Rl::Vector2, point_count:Integer, color:Rl::Color)  # Draw a triangle fan defined by points (first vertex is the center)
Rl.draw_triangle_strip(points:Rl::Vector2, point_count:Integer, color:Rl::Color)  # Draw a triangle strip defined by points
Rl.draw_poly(center:Rl::Vector2, sides:Integer, radius:Float, rotation:Float, color:Rl::Color)  # Draw a regular polygon (Vector version)
Rl.draw_poly_lines(center:Rl::Vector2, sides:Integer, radius:Float, rotation:Float, color:Rl::Color)  # Draw a polygon outline of n sides
Rl.draw_poly_lines_ex(center:Rl::Vector2, sides:Integer, radius:Float, rotation:Float, line_thick:Float, color:Rl::Color)  # Draw a polygon outline of n sides with extended parameters
Rl.draw_spline_linear(points:Rl::Vector2, point_count:Integer, thick:Float, color:Rl::Color)  # Draw spline: Linear, minimum 2 points
Rl.draw_spline_basis(points:Rl::Vector2, point_count:Integer, thick:Float, color:Rl::Color)  # Draw spline: B-Spline, minimum 4 points
Rl.draw_spline_catmull_rom(points:Rl::Vector2, point_count:Integer, thick:Float, color:Rl::Color)  # Draw spline: Catmull-Rom, minimum 4 points
Rl.draw_spline_bezier_quadratic(points:Rl::Vector2, point_count:Integer, thick:Float, color:Rl::Color)  # Draw spline: Quadratic Bezier, minimum 3 points (1 control point): [p1, c2, p3, c4...]
Rl.draw_spline_bezier_cubic(points:Rl::Vector2, point_count:Integer, thick:Float, color:Rl::Color)  # Draw spline: Cubic Bezier, minimum 4 points (2 control points): [p1, c2, c3, p4, c5, c6...]
Rl.draw_spline_segment_linear(p1:Rl::Vector2, p2:Rl::Vector2, thick:Float, color:Rl::Color)  # Draw spline segment: Linear, 2 points
Rl.draw_spline_segment_basis(p1:Rl::Vector2, p2:Rl::Vector2, p3:Rl::Vector2, p4:Rl::Vector2, thick:Float, color:Rl::Color)  # Draw spline segment: B-Spline, 4 points
Rl.draw_spline_segment_catmull_rom(p1:Rl::Vector2, p2:Rl::Vector2, p3:Rl::Vector2, p4:Rl::Vector2, thick:Float, color:Rl::Color)  # Draw spline segment: Catmull-Rom, 4 points
Rl.draw_spline_segment_bezier_quadratic(p1:Rl::Vector2, c2:Rl::Vector2, p3:Rl::Vector2, thick:Float, color:Rl::Color)  # Draw spline segment: Quadratic Bezier, 2 points, 1 control point
Rl.draw_spline_segment_bezier_cubic(p1:Rl::Vector2, c2:Rl::Vector2, c3:Rl::Vector2, p4:Rl::Vector2, thick:Float, color:Rl::Color)  # Draw spline segment: Cubic Bezier, 2 points, 2 control points
Rl.get_spline_point_linear(start_pos:Rl::Vector2, end_pos:Rl::Vector2, t:Float) -> Rl::Vector2  # Get (evaluate) spline point: Linear
Rl.get_spline_point_basis(p1:Rl::Vector2, p2:Rl::Vector2, p3:Rl::Vector2, p4:Rl::Vector2, t:Float) -> Rl::Vector2  # Get (evaluate) spline point: B-Spline
Rl.get_spline_point_catmull_rom(p1:Rl::Vector2, p2:Rl::Vector2, p3:Rl::Vector2, p4:Rl::Vector2, t:Float) -> Rl::Vector2  # Get (evaluate) spline point: Catmull-Rom
Rl.get_spline_point_bezier_quad(p1:Rl::Vector2, c2:Rl::Vector2, p3:Rl::Vector2, t:Float) -> Rl::Vector2  # Get (evaluate) spline point: Quadratic Bezier
Rl.get_spline_point_bezier_cubic(p1:Rl::Vector2, c2:Rl::Vector2, c3:Rl::Vector2, p4:Rl::Vector2, t:Float) -> Rl::Vector2  # Get (evaluate) spline point: Cubic Bezier
Rl.check_collision_recs(rec1:Rl::Rectangle, rec2:Rl::Rectangle) -> Boolean  # Check collision between two rectangles
Rl.check_collision_circles(center1:Rl::Vector2, radius1:Float, center2:Rl::Vector2, radius2:Float) -> Boolean  # Check collision between two circles
Rl.check_collision_circle_rec(center:Rl::Vector2, radius:Float, rec:Rl::Rectangle) -> Boolean  # Check collision between circle and rectangle
Rl.check_collision_circle_line(center:Rl::Vector2, radius:Float, p1:Rl::Vector2, p2:Rl::Vector2) -> Boolean  # Check if circle collides with a line created betweeen two points [p1] and [p2]
Rl.check_collision_point_rec(point:Rl::Vector2, rec:Rl::Rectangle) -> Boolean  # Check if point is inside rectangle
Rl.check_collision_point_circle(point:Rl::Vector2, center:Rl::Vector2, radius:Float) -> Boolean  # Check if point is inside circle
Rl.check_collision_point_triangle(point:Rl::Vector2, p1:Rl::Vector2, p2:Rl::Vector2, p3:Rl::Vector2) -> Boolean  # Check if point is inside a triangle
Rl.check_collision_point_line(point:Rl::Vector2, p1:Rl::Vector2, p2:Rl::Vector2, threshold:Integer) -> Boolean  # Check if point belongs to line created between two points [p1] and [p2] with defined margin in pixels [threshold]
Rl.check_collision_point_poly(point:Rl::Vector2, points:Rl::Vector2, point_count:Integer) -> Boolean  # Check if point is within a polygon described by array of vertices
Rl.check_collision_lines(start_pos1:Rl::Vector2, end_pos1:Rl::Vector2, start_pos2:Rl::Vector2, end_pos2:Rl::Vector2, collision_point:Rl::Vector2) -> Boolean  # Check the collision between two lines defined by two points each, returns collision point by reference
Rl.get_collision_rec(rec1:Rl::Rectangle, rec2:Rl::Rectangle) -> Rl::Rectangle  # Get collision rectangle for two rectangles collision
```

### textures
```ruby
Rl.load_image(file_name:String) -> Rl::Image  # Load image from file into CPU memory (RAM)
Rl.load_image_raw(file_name:String, width:Integer, height:Integer, format:Integer, header_size:Integer) -> Rl::Image  # Load image from RAW file data
Rl.load_image_from_texture(texture:Rl::Texture) -> Rl::Image  # Load image from GPU texture data
Rl.load_image_from_screen -> Rl::Image  # Load image from screen buffer and (screenshot)
Rl.image_valid?(image:Rl::Image) -> Boolean  # Check if an image is valid (data and parameters)
Rl.unload_image(image:Rl::Image)  # Unload image from CPU memory (RAM)
Rl.export_image(image:Rl::Image, file_name:String) -> Boolean  # Export image data to file, returns true on success
Rl.export_image_as_code(image:Rl::Image, file_name:String) -> Boolean  # Export image as code file defining an array of bytes, returns true on success
Rl.gen_image_color(width:Integer, height:Integer, color:Rl::Color) -> Rl::Image  # Generate image: plain color
Rl.gen_image_gradient_linear(width:Integer, height:Integer, direction:Integer, start:Rl::Color, end:Rl::Color) -> Rl::Image  # Generate image: linear gradient, direction in degrees [0..360], 0=Vertical gradient
Rl.gen_image_gradient_radial(width:Integer, height:Integer, density:Float, inner:Rl::Color, outer:Rl::Color) -> Rl::Image  # Generate image: radial gradient
Rl.gen_image_gradient_square(width:Integer, height:Integer, density:Float, inner:Rl::Color, outer:Rl::Color) -> Rl::Image  # Generate image: square gradient
Rl.gen_image_checked(width:Integer, height:Integer, checks_x:Integer, checks_y:Integer, col1:Rl::Color, col2:Rl::Color) -> Rl::Image  # Generate image: checked
Rl.gen_image_white_noise(width:Integer, height:Integer, factor:Float) -> Rl::Image  # Generate image: white noise
Rl.gen_image_perlin_noise(width:Integer, height:Integer, offset_x:Integer, offset_y:Integer, scale:Float) -> Rl::Image  # Generate image: perlin noise
Rl.gen_image_cellular(width:Integer, height:Integer, tile_size:Integer) -> Rl::Image  # Generate image: cellular algorithm, bigger tileSize means bigger cells
Rl.gen_image_text(width:Integer, height:Integer, text:String) -> Rl::Image  # Generate image: grayscale image from text data
Rl.image_copy(image:Rl::Image) -> Rl::Image  # Create an image duplicate (useful for transformations)
Rl.image_from_image(image:Rl::Image, rec:Rl::Rectangle) -> Rl::Image  # Create an image from another image piece
Rl.image_from_channel(image:Rl::Image, selected_channel:Integer) -> Rl::Image  # Create an image from a selected channel of another image (GRAYSCALE)
Rl.image_text(text:String, font_size:Integer, color:Rl::Color) -> Rl::Image  # Create an image from text (default font)
Rl.image_text_ex(font:Rl::Font, text:String, font_size:Float, spacing:Float, tint:Rl::Color) -> Rl::Image  # Create an image from text (custom sprite font)
Rl.image_format(image:Rl::Image, new_format:Integer)  # Convert image data to desired format
Rl.image_to_pot(image:Rl::Image, fill:Rl::Color)  # Convert image to POT (power-of-two)
Rl.image_crop(image:Rl::Image, crop:Rl::Rectangle)  # Crop an image to a defined rectangle
Rl.image_alpha_crop(image:Rl::Image, threshold:Float)  # Crop image depending on alpha value
Rl.image_alpha_clear(image:Rl::Image, color:Rl::Color, threshold:Float)  # Clear alpha channel to desired color
Rl.image_alpha_mask(image:Rl::Image, alpha_mask:Rl::Image)  # Apply alpha mask to image
Rl.image_alpha_premultiply(image:Rl::Image)  # Premultiply alpha channel
Rl.image_blur_gaussian(image:Rl::Image, blur_size:Integer)  # Apply Gaussian blur using a box blur approximation
Rl.image_resize(image:Rl::Image, new_width:Integer, new_height:Integer)  # Resize image (Bicubic scaling algorithm)
Rl.image_resize_nn(image:Rl::Image, new_width:Integer, new_height:Integer)  # Resize image (Nearest-Neighbor scaling algorithm)
Rl.image_resize_canvas(image:Rl::Image, new_width:Integer, new_height:Integer, offset_x:Integer, offset_y:Integer, fill:Rl::Color)  # Resize canvas and fill with color
Rl.image_mipmaps(image:Rl::Image)  # Compute all mipmap levels for a provided image
Rl.image_dither(image:Rl::Image, r_bpp:Integer, g_bpp:Integer, b_bpp:Integer, a_bpp:Integer)  # Dither image data to 16bpp or lower (Floyd-Steinberg dithering)
Rl.image_flip_vertical(image:Rl::Image)  # Flip image vertically
Rl.image_flip_horizontal(image:Rl::Image)  # Flip image horizontally
Rl.image_rotate(image:Rl::Image, degrees:Integer)  # Rotate image by input angle in degrees (-359 to 359)
Rl.image_rotate_cw(image:Rl::Image)  # Rotate image clockwise 90deg
Rl.image_rotate_ccw(image:Rl::Image)  # Rotate image counter-clockwise 90deg
Rl.image_color_tint(image:Rl::Image, color:Rl::Color)  # Modify image color: tint
Rl.image_color_invert(image:Rl::Image)  # Modify image color: invert
Rl.image_color_grayscale(image:Rl::Image)  # Modify image color: grayscale
Rl.image_color_contrast(image:Rl::Image, contrast:Float)  # Modify image color: contrast (-100 to 100)
Rl.image_color_brightness(image:Rl::Image, brightness:Integer)  # Modify image color: brightness (-255 to 255)
Rl.image_color_replace(image:Rl::Image, color:Rl::Color, replace:Rl::Color)  # Modify image color: replace color
Rl.unload_image_colors(colors:Rl::Color)  # Unload color data loaded with LoadImageColors()
Rl.unload_image_palette(colors:Rl::Color)  # Unload colors palette loaded with LoadImagePalette()
Rl.get_image_alpha_border(image:Rl::Image, threshold:Float) -> Rl::Rectangle  # Get image alpha border rectangle
Rl.get_image_color(image:Rl::Image, x:Integer, y:Integer) -> Rl::Color  # Get image pixel color at (x, y) position
Rl.image_clear_background(dst:Rl::Image, color:Rl::Color)  # Clear image background with given color
Rl.image_draw_pixel(dst:Rl::Image, pos_x:Integer, pos_y:Integer, color:Rl::Color)  # Draw pixel within an image
Rl.image_draw_pixel_v(dst:Rl::Image, position:Rl::Vector2, color:Rl::Color)  # Draw pixel within an image (Vector version)
Rl.image_draw_line(dst:Rl::Image, start_pos_x:Integer, start_pos_y:Integer, end_pos_x:Integer, end_pos_y:Integer, color:Rl::Color)  # Draw line within an image
Rl.image_draw_line_v(dst:Rl::Image, start:Rl::Vector2, end:Rl::Vector2, color:Rl::Color)  # Draw line within an image (Vector version)
Rl.image_draw_line_ex(dst:Rl::Image, start:Rl::Vector2, end:Rl::Vector2, thick:Integer, color:Rl::Color)  # Draw a line defining thickness within an image
Rl.image_draw_circle(dst:Rl::Image, center_x:Integer, center_y:Integer, radius:Integer, color:Rl::Color)  # Draw a filled circle within an image
Rl.image_draw_circle_v(dst:Rl::Image, center:Rl::Vector2, radius:Integer, color:Rl::Color)  # Draw a filled circle within an image (Vector version)
Rl.image_draw_circle_lines(dst:Rl::Image, center_x:Integer, center_y:Integer, radius:Integer, color:Rl::Color)  # Draw circle outline within an image
Rl.image_draw_circle_lines_v(dst:Rl::Image, center:Rl::Vector2, radius:Integer, color:Rl::Color)  # Draw circle outline within an image (Vector version)
Rl.image_draw_rectangle(dst:Rl::Image, pos_x:Integer, pos_y:Integer, width:Integer, height:Integer, color:Rl::Color)  # Draw rectangle within an image
Rl.image_draw_rectangle_v(dst:Rl::Image, position:Rl::Vector2, size:Rl::Vector2, color:Rl::Color)  # Draw rectangle within an image (Vector version)
Rl.image_draw_rectangle_rec(dst:Rl::Image, rec:Rl::Rectangle, color:Rl::Color)  # Draw rectangle within an image
Rl.image_draw_rectangle_lines(dst:Rl::Image, rec:Rl::Rectangle, thick:Integer, color:Rl::Color)  # Draw rectangle lines within an image
Rl.image_draw_triangle(dst:Rl::Image, v1:Rl::Vector2, v2:Rl::Vector2, v3:Rl::Vector2, color:Rl::Color)  # Draw triangle within an image
Rl.image_draw_triangle_ex(dst:Rl::Image, v1:Rl::Vector2, v2:Rl::Vector2, v3:Rl::Vector2, c1:Rl::Color, c2:Rl::Color, c3:Rl::Color)  # Draw triangle with interpolated colors within an image
Rl.image_draw_triangle_lines(dst:Rl::Image, v1:Rl::Vector2, v2:Rl::Vector2, v3:Rl::Vector2, color:Rl::Color)  # Draw triangle outline within an image
Rl.image_draw_triangle_fan(dst:Rl::Image, points:Rl::Vector2, point_count:Integer, color:Rl::Color)  # Draw a triangle fan defined by points within an image (first vertex is the center)
Rl.image_draw_triangle_strip(dst:Rl::Image, points:Rl::Vector2, point_count:Integer, color:Rl::Color)  # Draw a triangle strip defined by points within an image
Rl.image_draw(dst:Rl::Image, src:Rl::Image, src_rec:Rl::Rectangle, dst_rec:Rl::Rectangle, tint:Rl::Color)  # Draw a source image within a destination image (tint applied to source)
Rl.image_draw_text(dst:Rl::Image, text:String, pos_x:Integer, pos_y:Integer, font_size:Integer, color:Rl::Color)  # Draw text (using default font) within an image (destination)
Rl.image_draw_text_ex(dst:Rl::Image, font:Rl::Font, text:String, position:Rl::Vector2, font_size:Float, spacing:Float, tint:Rl::Color)  # Draw text (custom sprite font) within an image (destination)
Rl.load_texture(file_name:String) -> Rl::Texture  # Load texture from file into GPU memory (VRAM)
Rl.load_texture_from_image(image:Rl::Image) -> Rl::Texture  # Load texture from image data
Rl.load_texture_cubemap(image:Rl::Image, layout:Integer) -> Rl::Texture  # Load cubemap from image, multiple image cubemap layouts supported
Rl.load_render_texture(width:Integer, height:Integer) -> Rl::RenderTexture  # Load texture for rendering (framebuffer)
Rl.texture_valid?(texture:Rl::Texture) -> Boolean  # Check if a texture is valid (loaded in GPU)
Rl.unload_texture(texture:Rl::Texture)  # Unload texture from GPU memory (VRAM)
Rl.render_texture_valid?(target:Rl::RenderTexture) -> Boolean  # Check if a render texture is valid (loaded in GPU)
Rl.unload_render_texture(target:Rl::RenderTexture)  # Unload render texture from GPU memory (VRAM)
Rl.gen_texture_mipmaps(texture:Rl::Texture)  # Generate GPU mipmaps for a texture
Rl.set_texture_filter(texture:Rl::Texture, filter:Integer)  # Set texture scaling filter mode
Rl.set_texture_wrap(texture:Rl::Texture, wrap:Integer)  # Set texture wrapping mode
Rl.draw_texture(texture:Rl::Texture, pos_x:Integer, pos_y:Integer, tint:Rl::Color)  # Draw a Texture2D
Rl.draw_texture_v(texture:Rl::Texture, position:Rl::Vector2, tint:Rl::Color)  # Draw a Texture2D with position defined as Vector2
Rl.draw_texture_ex(texture:Rl::Texture, position:Rl::Vector2, rotation:Float, scale:Float, tint:Rl::Color)  # Draw a Texture2D with extended parameters
Rl.draw_texture_rec(texture:Rl::Texture, source:Rl::Rectangle, position:Rl::Vector2, tint:Rl::Color)  # Draw a part of a texture defined by a rectangle
Rl.draw_texture_pro(texture:Rl::Texture, source:Rl::Rectangle, dest:Rl::Rectangle, origin:Rl::Vector2, rotation:Float, tint:Rl::Color)  # Draw a part of a texture defined by a rectangle with 'pro' parameters
Rl.draw_texture_n_patch(texture:Rl::Texture, n_patch_info:Rl::NPatchInfo, dest:Rl::Rectangle, origin:Rl::Vector2, rotation:Float, tint:Rl::Color)  # Draws a texture (or part of it) that stretches or shrinks nicely
Rl.color_is_equal(col1:Rl::Color, col2:Rl::Color) -> Boolean  # Check if two colors are equal
Rl.fade(color:Rl::Color, alpha:Float) -> Rl::Color  # Get color with alpha applied, alpha goes from 0.0f to 1.0f
Rl.color_to_int(color:Rl::Color) -> Integer  # Get hexadecimal value for a Color (0xRRGGBBAA)
Rl.color_normalize(color:Rl::Color) -> Rl::Vector4  # Get Color normalized as float [0..1]
Rl.color_from_normalized(normalized:Rl::Vector4) -> Rl::Color  # Get Color from normalized values [0..1]
Rl.color_to_hsv(color:Rl::Color) -> Rl::Vector3  # Get HSV values for a Color, hue [0..360], saturation/value [0..1]
Rl.color_from_hsv(hue:Float, saturation:Float, value:Float) -> Rl::Color  # Get a Color from HSV values, hue [0..360], saturation/value [0..1]
Rl.color_tint(color:Rl::Color, tint:Rl::Color) -> Rl::Color  # Get color multiplied with another color
Rl.color_brightness(color:Rl::Color, factor:Float) -> Rl::Color  # Get color with brightness correction, brightness factor goes from -1.0f to 1.0f
Rl.color_contrast(color:Rl::Color, contrast:Float) -> Rl::Color  # Get color with contrast correction, contrast values between -1.0f and 1.0f
Rl.color_alpha(color:Rl::Color, alpha:Float) -> Rl::Color  # Get color with alpha applied, alpha goes from 0.0f to 1.0f
Rl.color_alpha_blend(dst:Rl::Color, src:Rl::Color, tint:Rl::Color) -> Rl::Color  # Get src alpha-blended into dst color with tint
Rl.color_lerp(color1:Rl::Color, color2:Rl::Color, factor:Float) -> Rl::Color  # Get color lerp interpolation between two colors, factor [0.0f..1.0f]
Rl.get_color(hex_value:Integer) -> Rl::Color  # Get Color structure from hexadecimal value
Rl.get_pixel_data_size(width:Integer, height:Integer, format:Integer) -> Integer  # Get pixel data size in bytes for certain format
```

### text
```ruby
Rl.get_font_default -> Rl::Font  # Get the default Font
Rl.load_font(file_name:String) -> Rl::Font  # Load font from file into GPU memory (VRAM)
Rl.load_font_from_image(image:Rl::Image, key:Rl::Color, first_char:Integer) -> Rl::Font  # Load font from Image (XNA style)
Rl.font_valid?(font:Rl::Font) -> Boolean  # Check if a font is valid (font data loaded, WARNING: GPU texture not checked)
Rl.unload_font_data(glyphs:Rl::GlyphInfo, glyph_count:Integer)  # Unload font chars info data (RAM)
Rl.unload_font(font:Rl::Font)  # Unload font from GPU memory (VRAM)
Rl.export_font_as_code(font:Rl::Font, file_name:String) -> Boolean  # Export font as code file, returns true on success
Rl.draw_fps(pos_x:Integer, pos_y:Integer)  # Draw current FPS
Rl.draw_text(text:String, pos_x:Integer, pos_y:Integer, font_size:Integer, color:Rl::Color)  # Draw text (using default font)
Rl.draw_text_ex(font:Rl::Font, text:String, position:Rl::Vector2, font_size:Float, spacing:Float, tint:Rl::Color)  # Draw text using font and additional parameters
Rl.draw_text_pro(font:Rl::Font, text:String, position:Rl::Vector2, origin:Rl::Vector2, rotation:Float, font_size:Float, spacing:Float, tint:Rl::Color)  # Draw text using Font and pro parameters (rotation)
Rl.draw_text_codepoint(font:Rl::Font, codepoint:Integer, position:Rl::Vector2, font_size:Float, tint:Rl::Color)  # Draw one character (codepoint)
Rl.set_text_line_spacing(spacing:Integer)  # Set vertical line spacing when drawing with line-breaks
Rl.measure_text(text:String, font_size:Integer) -> Integer  # Measure string width for default font
Rl.measure_text_ex(font:Rl::Font, text:String, font_size:Float, spacing:Float) -> Rl::Vector2  # Measure string size for Font
Rl.get_glyph_index(font:Rl::Font, codepoint:Integer) -> Integer  # Get glyph index position in font for a codepoint (unicode character), fallback to '?' if not found
Rl.get_glyph_info(font:Rl::Font, codepoint:Integer) -> Rl::GlyphInfo  # Get glyph font info data for a codepoint (unicode character), fallback to '?' if not found
Rl.get_glyph_atlas_rec(font:Rl::Font, codepoint:Integer) -> Rl::Rectangle  # Get glyph rectangle in font atlas for a codepoint (unicode character), fallback to '?' if not found
Rl.get_codepoint_count(text:String) -> Integer  # Get total number of codepoints in a UTF-8 encoded string
Rl.text_is_equal(text1:String, text2:String) -> Boolean  # Check if two text string are equal
Rl.text_length(text:String) -> Integer  # Get text length, checks for '\0' ending
Rl.text_subtext(text:String, position:Integer, length:Integer) -> String  # Get a piece of a text string
Rl.text_remove_spaces(text:String) -> String  # Remove text spaces, concat words
Rl.get_text_between(text:String, begin:String, end:String) -> String  # Get text between two strings
Rl.text_replace(text:String, search:String, replacement:String) -> String  # Replace text string with new string
Rl.text_replace_alloc(text:String, search:String, replacement:String) -> String  # Replace text string with new string, memory must be MemFree()
Rl.text_replace_between(text:String, begin:String, end:String, replacement:String) -> String  # Replace text between two specific strings
Rl.text_replace_between_alloc(text:String, begin:String, end:String, replacement:String) -> String  # Replace text between two specific strings, memory must be MemFree()
Rl.text_insert(text:String, insert:String, position:Integer) -> String  # Insert text in a defined byte position
Rl.text_insert_alloc(text:String, insert:String, position:Integer) -> String  # Insert text in a defined byte position, memory must be MemFree()
Rl.text_find_index(text:String, search:String) -> Integer  # Find first text occurrence within a string, -1 if not found
Rl.text_to_upper(text:String) -> String  # Get upper case version of provided string
Rl.text_to_lower(text:String) -> String  # Get lower case version of provided string
Rl.text_to_pascal(text:String) -> String  # Get Pascal case notation version of provided string
Rl.text_to_snake(text:String) -> String  # Get Snake case notation version of provided string
Rl.text_to_camel(text:String) -> String  # Get Camel case notation version of provided string
Rl.text_to_integer(text:String) -> Integer  # Get integer value from text
Rl.text_to_float(text:String) -> Float  # Get float value from text
```

### models
```ruby
Rl.draw_line3d(start_pos:Rl::Vector3, end_pos:Rl::Vector3, color:Rl::Color)  # Draw a line in 3D world space
Rl.draw_point3d(position:Rl::Vector3, color:Rl::Color)  # Draw a point in 3D space, actually a small line
Rl.draw_circle3d(center:Rl::Vector3, radius:Float, rotation_axis:Rl::Vector3, rotation_angle:Float, color:Rl::Color)  # Draw a circle in 3D world space
Rl.draw_triangle3d(v1:Rl::Vector3, v2:Rl::Vector3, v3:Rl::Vector3, color:Rl::Color)  # Draw a color-filled triangle (vertex in counter-clockwise order!)
Rl.draw_triangle_strip3d(points:Rl::Vector3, point_count:Integer, color:Rl::Color)  # Draw a triangle strip defined by points
Rl.draw_cube(position:Rl::Vector3, width:Float, height:Float, length:Float, color:Rl::Color)  # Draw cube
Rl.draw_cube_v(position:Rl::Vector3, size:Rl::Vector3, color:Rl::Color)  # Draw cube (Vector version)
Rl.draw_cube_wires(position:Rl::Vector3, width:Float, height:Float, length:Float, color:Rl::Color)  # Draw cube wires
Rl.draw_cube_wires_v(position:Rl::Vector3, size:Rl::Vector3, color:Rl::Color)  # Draw cube wires (Vector version)
Rl.draw_sphere(center_pos:Rl::Vector3, radius:Float, color:Rl::Color)  # Draw sphere
Rl.draw_sphere_ex(center_pos:Rl::Vector3, radius:Float, rings:Integer, slices:Integer, color:Rl::Color)  # Draw sphere with extended parameters
Rl.draw_sphere_wires(center_pos:Rl::Vector3, radius:Float, rings:Integer, slices:Integer, color:Rl::Color)  # Draw sphere wires
Rl.draw_cylinder(position:Rl::Vector3, radius_top:Float, radius_bottom:Float, height:Float, slices:Integer, color:Rl::Color)  # Draw a cylinder/cone
Rl.draw_cylinder_ex(start_pos:Rl::Vector3, end_pos:Rl::Vector3, start_radius:Float, end_radius:Float, sides:Integer, color:Rl::Color)  # Draw a cylinder with base at startPos and top at endPos
Rl.draw_cylinder_wires(position:Rl::Vector3, radius_top:Float, radius_bottom:Float, height:Float, slices:Integer, color:Rl::Color)  # Draw a cylinder/cone wires
Rl.draw_cylinder_wires_ex(start_pos:Rl::Vector3, end_pos:Rl::Vector3, start_radius:Float, end_radius:Float, sides:Integer, color:Rl::Color)  # Draw a cylinder wires with base at startPos and top at endPos
Rl.draw_capsule(start_pos:Rl::Vector3, end_pos:Rl::Vector3, radius:Float, slices:Integer, rings:Integer, color:Rl::Color)  # Draw a capsule with the center of its sphere caps at startPos and endPos
Rl.draw_capsule_wires(start_pos:Rl::Vector3, end_pos:Rl::Vector3, radius:Float, slices:Integer, rings:Integer, color:Rl::Color)  # Draw capsule wireframe with the center of its sphere caps at startPos and endPos
Rl.draw_plane(center_pos:Rl::Vector3, size:Rl::Vector2, color:Rl::Color)  # Draw a plane XZ
Rl.draw_ray(ray:Rl::Ray, color:Rl::Color)  # Draw a ray line
Rl.draw_grid(slices:Integer, spacing:Float)  # Draw a grid (centered at (0, 0, 0))
Rl.load_model(file_name:String) -> Rl::Model  # Load model from files (meshes and materials)
Rl.load_model_from_mesh(mesh:Rl::Mesh) -> Rl::Model  # Load model from generated mesh (default material)
Rl.model_valid?(model:Rl::Model) -> Boolean  # Check if a model is valid (loaded in GPU, VAO/VBOs)
Rl.unload_model(model:Rl::Model)  # Unload model (including meshes) from memory (RAM and/or VRAM)
Rl.get_model_bounding_box(model:Rl::Model) -> Rl::BoundingBox  # Compute model bounding box limits (considers all meshes)
Rl.draw_model(model:Rl::Model, position:Rl::Vector3, scale:Float, tint:Rl::Color)  # Draw a model (with texture if set)
Rl.draw_model_ex(model:Rl::Model, position:Rl::Vector3, rotation_axis:Rl::Vector3, rotation_angle:Float, scale:Rl::Vector3, tint:Rl::Color)  # Draw a model with extended parameters
Rl.draw_model_wires(model:Rl::Model, position:Rl::Vector3, scale:Float, tint:Rl::Color)  # Draw a model wires (with texture if set)
Rl.draw_model_wires_ex(model:Rl::Model, position:Rl::Vector3, rotation_axis:Rl::Vector3, rotation_angle:Float, scale:Rl::Vector3, tint:Rl::Color)  # Draw a model wires (with texture if set) with extended parameters
Rl.draw_bounding_box(box:Rl::BoundingBox, color:Rl::Color)  # Draw bounding box (wires)
Rl.draw_billboard(camera:Rl::Camera3D, texture:Rl::Texture, position:Rl::Vector3, scale:Float, tint:Rl::Color)  # Draw a billboard texture
Rl.draw_billboard_rec(camera:Rl::Camera3D, texture:Rl::Texture, source:Rl::Rectangle, position:Rl::Vector3, size:Rl::Vector2, tint:Rl::Color)  # Draw a billboard texture defined by source
Rl.draw_billboard_pro(camera:Rl::Camera3D, texture:Rl::Texture, source:Rl::Rectangle, position:Rl::Vector3, up:Rl::Vector3, size:Rl::Vector2, origin:Rl::Vector2, rotation:Float, tint:Rl::Color)  # Draw a billboard texture defined by source and rotation
Rl.upload_mesh(mesh:Rl::Mesh, dynamic:Boolean)  # Upload mesh vertex data in GPU and provide VAO/VBO ids
Rl.unload_mesh(mesh:Rl::Mesh)  # Unload mesh data from CPU and GPU
Rl.draw_mesh(mesh:Rl::Mesh, material:Rl::Material, transform:Rl::Matrix)  # Draw a 3d mesh with material and transform
Rl.draw_mesh_instanced(mesh:Rl::Mesh, material:Rl::Material, transforms:Rl::Matrix, instances:Integer)  # Draw multiple mesh instances with material and different transforms
Rl.get_mesh_bounding_box(mesh:Rl::Mesh) -> Rl::BoundingBox  # Compute mesh bounding box limits
Rl.gen_mesh_tangents(mesh:Rl::Mesh)  # Compute mesh tangents
Rl.export_mesh(mesh:Rl::Mesh, file_name:String) -> Boolean  # Export mesh data to file, returns true on success
Rl.export_mesh_as_code(mesh:Rl::Mesh, file_name:String) -> Boolean  # Export mesh as code file (.h) defining multiple arrays of vertex attributes
Rl.gen_mesh_poly(sides:Integer, radius:Float) -> Rl::Mesh  # Generate polygonal mesh
Rl.gen_mesh_plane(width:Float, length:Float, res_x:Integer, res_z:Integer) -> Rl::Mesh  # Generate plane mesh (with subdivisions)
Rl.gen_mesh_cube(width:Float, height:Float, length:Float) -> Rl::Mesh  # Generate cuboid mesh
Rl.gen_mesh_sphere(radius:Float, rings:Integer, slices:Integer) -> Rl::Mesh  # Generate sphere mesh (standard sphere)
Rl.gen_mesh_hemi_sphere(radius:Float, rings:Integer, slices:Integer) -> Rl::Mesh  # Generate half-sphere mesh (no bottom cap)
Rl.gen_mesh_cylinder(radius:Float, height:Float, slices:Integer) -> Rl::Mesh  # Generate cylinder mesh
Rl.gen_mesh_cone(radius:Float, height:Float, slices:Integer) -> Rl::Mesh  # Generate cone/pyramid mesh
Rl.gen_mesh_torus(radius:Float, size:Float, rad_seg:Integer, sides:Integer) -> Rl::Mesh  # Generate torus mesh
Rl.gen_mesh_knot(radius:Float, size:Float, rad_seg:Integer, sides:Integer) -> Rl::Mesh  # Generate trefoil knot mesh
Rl.gen_mesh_heightmap(heightmap:Rl::Image, size:Rl::Vector3) -> Rl::Mesh  # Generate heightmap mesh from image data
Rl.gen_mesh_cubicmap(cubicmap:Rl::Image, cube_size:Rl::Vector3) -> Rl::Mesh  # Generate cubes-based map mesh from image data
Rl.load_material_default -> Rl::Material  # Load default material (Supports: DIFFUSE, SPECULAR, NORMAL maps)
Rl.material_valid?(material:Rl::Material) -> Boolean  # Check if a material is valid (shader assigned, map textures loaded in GPU)
Rl.unload_material(material:Rl::Material)  # Unload material from GPU memory (VRAM)
Rl.set_material_texture(material:Rl::Material, map_type:Integer, texture:Rl::Texture)  # Set texture for a material map type (MATERIAL_MAP_DIFFUSE, MATERIAL_MAP_SPECULAR...)
Rl.set_model_mesh_material(model:Rl::Model, mesh_id:Integer, material_id:Integer)  # Set material for a mesh
Rl.update_model_animation(model:Rl::Model, anim:Rl::ModelAnimation, frame:Float)  # Update model animation pose (vertex buffers and bone matrices)
Rl.update_model_animation_ex(model:Rl::Model, anim_a:Rl::ModelAnimation, frame_a:Float, anim_b:Rl::ModelAnimation, frame_b:Float, blend:Float)  # Update model animation pose, blending two animations
Rl.unload_model_animations(animations:Rl::ModelAnimation, anim_count:Integer)  # Unload animation array data
Rl.model_animation_valid?(model:Rl::Model, anim:Rl::ModelAnimation) -> Boolean  # Check model animation skeleton match
Rl.check_collision_spheres(center1:Rl::Vector3, radius1:Float, center2:Rl::Vector3, radius2:Float) -> Boolean  # Check collision between two spheres
Rl.check_collision_boxes(box1:Rl::BoundingBox, box2:Rl::BoundingBox) -> Boolean  # Check collision between two bounding boxes
Rl.check_collision_box_sphere(box:Rl::BoundingBox, center:Rl::Vector3, radius:Float) -> Boolean  # Check collision between box and sphere
Rl.get_ray_collision_sphere(ray:Rl::Ray, center:Rl::Vector3, radius:Float) -> Rl::RayCollision  # Get collision info between ray and sphere
Rl.get_ray_collision_box(ray:Rl::Ray, box:Rl::BoundingBox) -> Rl::RayCollision  # Get collision info between ray and box
Rl.get_ray_collision_mesh(ray:Rl::Ray, mesh:Rl::Mesh, transform:Rl::Matrix) -> Rl::RayCollision  # Get collision info between ray and mesh
Rl.get_ray_collision_triangle(ray:Rl::Ray, p1:Rl::Vector3, p2:Rl::Vector3, p3:Rl::Vector3) -> Rl::RayCollision  # Get collision info between ray and triangle
Rl.get_ray_collision_quad(ray:Rl::Ray, p1:Rl::Vector3, p2:Rl::Vector3, p3:Rl::Vector3, p4:Rl::Vector3) -> Rl::RayCollision  # Get collision info between ray and quad
```

### audio
```ruby
Rl.init_audio_device  # Initialize audio device and context
Rl.close_audio_device  # Close the audio device and context
Rl.audio_device_ready? -> Boolean  # Check if audio device has been initialized successfully
Rl.set_master_volume(volume:Float)  # Set master volume (listener)
Rl.get_master_volume -> Float  # Get master volume (listener)
Rl.load_wave(file_name:String) -> Rl::Wave  # Load wave data from file
Rl.wave_valid?(wave:Rl::Wave) -> Boolean  # Checks if wave data is valid (data loaded and parameters)
Rl.load_sound(file_name:String) -> Rl::Sound  # Load sound from file
Rl.load_sound_from_wave(wave:Rl::Wave) -> Rl::Sound  # Load sound from wave data
Rl.load_sound_alias(source:Rl::Sound) -> Rl::Sound  # Create a new sound that shares the same sample data as the source sound, does not own the sound data
Rl.sound_valid?(sound:Rl::Sound) -> Boolean  # Checks if a sound is valid (data loaded and buffers initialized)
Rl.unload_wave(wave:Rl::Wave)  # Unload wave data
Rl.unload_sound(sound:Rl::Sound)  # Unload sound
Rl.unload_sound_alias(alias:Rl::Sound)  # Unload a sound alias (does not deallocate sample data)
Rl.export_wave(wave:Rl::Wave, file_name:String) -> Boolean  # Export wave data to file, returns true on success
Rl.export_wave_as_code(wave:Rl::Wave, file_name:String) -> Boolean  # Export wave sample data to code (.h), returns true on success
Rl.play_sound(sound:Rl::Sound)  # Play a sound
Rl.stop_sound(sound:Rl::Sound)  # Stop playing a sound
Rl.pause_sound(sound:Rl::Sound)  # Pause a sound
Rl.resume_sound(sound:Rl::Sound)  # Resume a paused sound
Rl.sound_playing?(sound:Rl::Sound) -> Boolean  # Check if a sound is currently playing
Rl.set_sound_volume(sound:Rl::Sound, volume:Float)  # Set volume for a sound (1.0 is max level)
Rl.set_sound_pitch(sound:Rl::Sound, pitch:Float)  # Set pitch for a sound (1.0 is base level)
Rl.set_sound_pan(sound:Rl::Sound, pan:Float)  # Set pan for a sound (-1.0 left, 0.0 center, 1.0 right)
Rl.wave_copy(wave:Rl::Wave) -> Rl::Wave  # Copy a wave to a new wave
Rl.wave_crop(wave:Rl::Wave, init_frame:Integer, final_frame:Integer)  # Crop a wave to defined frames range
Rl.wave_format(wave:Rl::Wave, sample_rate:Integer, sample_size:Integer, channels:Integer)  # Convert wave data to desired format
Rl.load_music_stream(file_name:String) -> Rl::Music  # Load music stream from file
Rl.music_valid?(music:Rl::Music) -> Boolean  # Checks if a music stream is valid (context and buffers initialized)
Rl.unload_music_stream(music:Rl::Music)  # Unload music stream
Rl.play_music_stream(music:Rl::Music)  # Start music playing
Rl.music_stream_playing?(music:Rl::Music) -> Boolean  # Check if music is playing
Rl.update_music_stream(music:Rl::Music)  # Updates buffers for music streaming
Rl.stop_music_stream(music:Rl::Music)  # Stop music playing
Rl.pause_music_stream(music:Rl::Music)  # Pause music playing
Rl.resume_music_stream(music:Rl::Music)  # Resume playing paused music
Rl.seek_music_stream(music:Rl::Music, position:Float)  # Seek music to a position (in seconds)
Rl.set_music_volume(music:Rl::Music, volume:Float)  # Set volume for music (1.0 is max level)
Rl.set_music_pitch(music:Rl::Music, pitch:Float)  # Set pitch for a music (1.0 is base level)
Rl.set_music_pan(music:Rl::Music, pan:Float)  # Set pan for a music (-1.0 left, 0.0 center, 1.0 right)
Rl.get_music_time_length(music:Rl::Music) -> Float  # Get music time length (in seconds)
Rl.get_music_time_played(music:Rl::Music) -> Float  # Get current music time played (in seconds)
Rl.load_audio_stream(sample_rate:Integer, sample_size:Integer, channels:Integer) -> Rl::AudioStream  # Load audio stream (to stream raw audio pcm data)
Rl.audio_stream_valid?(stream:Rl::AudioStream) -> Boolean  # Checks if an audio stream is valid (buffers initialized)
Rl.unload_audio_stream(stream:Rl::AudioStream)  # Unload audio stream and free memory
Rl.audio_stream_processed?(stream:Rl::AudioStream) -> Boolean  # Check if any audio stream buffers requires refill
Rl.play_audio_stream(stream:Rl::AudioStream)  # Play audio stream
Rl.pause_audio_stream(stream:Rl::AudioStream)  # Pause audio stream
Rl.resume_audio_stream(stream:Rl::AudioStream)  # Resume audio stream
Rl.audio_stream_playing?(stream:Rl::AudioStream) -> Boolean  # Check if audio stream is playing
Rl.stop_audio_stream(stream:Rl::AudioStream)  # Stop audio stream
Rl.set_audio_stream_volume(stream:Rl::AudioStream, volume:Float)  # Set volume for audio stream (1.0 is max level)
Rl.set_audio_stream_pitch(stream:Rl::AudioStream, pitch:Float)  # Set pitch for audio stream (1.0 is base level)
Rl.set_audio_stream_pan(stream:Rl::AudioStream, pan:Float)  # Set pan for audio stream (-1.0 to 1.0 range, 0.0 is centered)
Rl.set_audio_stream_buffer_size_default(size:Integer)  # Default size for new audio streams
```

## raymath functions
```ruby
Rl.clamp(value:Float, min:Float, max:Float) -> Float
Rl.lerp(start:Float, end:Float, amount:Float) -> Float
Rl.normalize(value:Float, start:Float, end:Float) -> Float
Rl.remap(value:Float, input_start:Float, input_end:Float, output_start:Float, output_end:Float) -> Float
Rl.wrap(value:Float, min:Float, max:Float) -> Float
Rl.float_equals(x:Float, y:Float) -> Integer
Rl.vector2_zero -> Rl::Vector2
Rl.vector2_one -> Rl::Vector2
Rl.vector2_add(v1:Rl::Vector2, v2:Rl::Vector2) -> Rl::Vector2
Rl.vector2_add_value(v:Rl::Vector2, add:Float) -> Rl::Vector2
Rl.vector2_subtract(v1:Rl::Vector2, v2:Rl::Vector2) -> Rl::Vector2
Rl.vector2_subtract_value(v:Rl::Vector2, sub:Float) -> Rl::Vector2
Rl.vector2_length(v:Rl::Vector2) -> Float
Rl.vector2_length_sqr(v:Rl::Vector2) -> Float
Rl.vector2_dot_product(v1:Rl::Vector2, v2:Rl::Vector2) -> Float
Rl.vector2_cross_product(v1:Rl::Vector2, v2:Rl::Vector2) -> Float
Rl.vector2_distance(v1:Rl::Vector2, v2:Rl::Vector2) -> Float
Rl.vector2_distance_sqr(v1:Rl::Vector2, v2:Rl::Vector2) -> Float
Rl.vector2_angle(v1:Rl::Vector2, v2:Rl::Vector2) -> Float
Rl.vector2_line_angle(start:Rl::Vector2, end:Rl::Vector2) -> Float
Rl.vector2_scale(v:Rl::Vector2, scale:Float) -> Rl::Vector2
Rl.vector2_multiply(v1:Rl::Vector2, v2:Rl::Vector2) -> Rl::Vector2
Rl.vector2_negate(v:Rl::Vector2) -> Rl::Vector2
Rl.vector2_divide(v1:Rl::Vector2, v2:Rl::Vector2) -> Rl::Vector2
Rl.vector2_normalize(v:Rl::Vector2) -> Rl::Vector2
Rl.vector2_transform(v:Rl::Vector2, mat:Rl::Matrix) -> Rl::Vector2
Rl.vector2_lerp(v1:Rl::Vector2, v2:Rl::Vector2, amount:Float) -> Rl::Vector2
Rl.vector2_reflect(v:Rl::Vector2, normal:Rl::Vector2) -> Rl::Vector2
Rl.vector2_min(v1:Rl::Vector2, v2:Rl::Vector2) -> Rl::Vector2
Rl.vector2_max(v1:Rl::Vector2, v2:Rl::Vector2) -> Rl::Vector2
Rl.vector2_rotate(v:Rl::Vector2, angle:Float) -> Rl::Vector2
Rl.vector2_move_towards(v:Rl::Vector2, target:Rl::Vector2, max_distance:Float) -> Rl::Vector2
Rl.vector2_invert(v:Rl::Vector2) -> Rl::Vector2
Rl.vector2_clamp(v:Rl::Vector2, min:Rl::Vector2, max:Rl::Vector2) -> Rl::Vector2
Rl.vector2_clamp_value(v:Rl::Vector2, min:Float, max:Float) -> Rl::Vector2
Rl.vector2_equals(p:Rl::Vector2, q:Rl::Vector2) -> Integer
Rl.vector2_refract(v:Rl::Vector2, n:Rl::Vector2, r:Float) -> Rl::Vector2
Rl.vector3_zero -> Rl::Vector3
Rl.vector3_one -> Rl::Vector3
Rl.vector3_add(v1:Rl::Vector3, v2:Rl::Vector3) -> Rl::Vector3
Rl.vector3_add_value(v:Rl::Vector3, add:Float) -> Rl::Vector3
Rl.vector3_subtract(v1:Rl::Vector3, v2:Rl::Vector3) -> Rl::Vector3
Rl.vector3_subtract_value(v:Rl::Vector3, sub:Float) -> Rl::Vector3
Rl.vector3_scale(v:Rl::Vector3, scalar:Float) -> Rl::Vector3
Rl.vector3_multiply(v1:Rl::Vector3, v2:Rl::Vector3) -> Rl::Vector3
Rl.vector3_cross_product(v1:Rl::Vector3, v2:Rl::Vector3) -> Rl::Vector3
Rl.vector3_perpendicular(v:Rl::Vector3) -> Rl::Vector3
Rl.vector3_length(v:Rl::Vector3) -> Float
Rl.vector3_length_sqr(v:Rl::Vector3) -> Float
Rl.vector3_dot_product(v1:Rl::Vector3, v2:Rl::Vector3) -> Float
Rl.vector3_distance(v1:Rl::Vector3, v2:Rl::Vector3) -> Float
Rl.vector3_distance_sqr(v1:Rl::Vector3, v2:Rl::Vector3) -> Float
Rl.vector3_angle(v1:Rl::Vector3, v2:Rl::Vector3) -> Float
Rl.vector3_negate(v:Rl::Vector3) -> Rl::Vector3
Rl.vector3_divide(v1:Rl::Vector3, v2:Rl::Vector3) -> Rl::Vector3
Rl.vector3_normalize(v:Rl::Vector3) -> Rl::Vector3
Rl.vector3_project(v1:Rl::Vector3, v2:Rl::Vector3) -> Rl::Vector3
Rl.vector3_reject(v1:Rl::Vector3, v2:Rl::Vector3) -> Rl::Vector3
Rl.vector3_ortho_normalize(v1:Rl::Vector3, v2:Rl::Vector3)
Rl.vector3_transform(v:Rl::Vector3, mat:Rl::Matrix) -> Rl::Vector3
Rl.vector3_rotate_by_quaternion(v:Rl::Vector3, q:Rl::Vector4) -> Rl::Vector3
Rl.vector3_rotate_by_axis_angle(v:Rl::Vector3, axis:Rl::Vector3, angle:Float) -> Rl::Vector3
Rl.vector3_move_towards(v:Rl::Vector3, target:Rl::Vector3, max_distance:Float) -> Rl::Vector3
Rl.vector3_lerp(v1:Rl::Vector3, v2:Rl::Vector3, amount:Float) -> Rl::Vector3
Rl.vector3_cubic_hermite(v1:Rl::Vector3, tangent1:Rl::Vector3, v2:Rl::Vector3, tangent2:Rl::Vector3, amount:Float) -> Rl::Vector3
Rl.vector3_reflect(v:Rl::Vector3, normal:Rl::Vector3) -> Rl::Vector3
Rl.vector3_min(v1:Rl::Vector3, v2:Rl::Vector3) -> Rl::Vector3
Rl.vector3_max(v1:Rl::Vector3, v2:Rl::Vector3) -> Rl::Vector3
Rl.vector3_barycenter(p:Rl::Vector3, a:Rl::Vector3, b:Rl::Vector3, c:Rl::Vector3) -> Rl::Vector3
Rl.vector3_unproject(source:Rl::Vector3, projection:Rl::Matrix, view:Rl::Matrix) -> Rl::Vector3
Rl.vector3_invert(v:Rl::Vector3) -> Rl::Vector3
Rl.vector3_clamp(v:Rl::Vector3, min:Rl::Vector3, max:Rl::Vector3) -> Rl::Vector3
Rl.vector3_clamp_value(v:Rl::Vector3, min:Float, max:Float) -> Rl::Vector3
Rl.vector3_equals(p:Rl::Vector3, q:Rl::Vector3) -> Integer
Rl.vector3_refract(v:Rl::Vector3, n:Rl::Vector3, r:Float) -> Rl::Vector3
Rl.vector4_zero -> Rl::Vector4
Rl.vector4_one -> Rl::Vector4
Rl.vector4_add(v1:Rl::Vector4, v2:Rl::Vector4) -> Rl::Vector4
Rl.vector4_add_value(v:Rl::Vector4, add:Float) -> Rl::Vector4
Rl.vector4_subtract(v1:Rl::Vector4, v2:Rl::Vector4) -> Rl::Vector4
Rl.vector4_subtract_value(v:Rl::Vector4, add:Float) -> Rl::Vector4
Rl.vector4_length(v:Rl::Vector4) -> Float
Rl.vector4_length_sqr(v:Rl::Vector4) -> Float
Rl.vector4_dot_product(v1:Rl::Vector4, v2:Rl::Vector4) -> Float
Rl.vector4_distance(v1:Rl::Vector4, v2:Rl::Vector4) -> Float
Rl.vector4_distance_sqr(v1:Rl::Vector4, v2:Rl::Vector4) -> Float
Rl.vector4_scale(v:Rl::Vector4, scale:Float) -> Rl::Vector4
Rl.vector4_multiply(v1:Rl::Vector4, v2:Rl::Vector4) -> Rl::Vector4
Rl.vector4_negate(v:Rl::Vector4) -> Rl::Vector4
Rl.vector4_divide(v1:Rl::Vector4, v2:Rl::Vector4) -> Rl::Vector4
Rl.vector4_normalize(v:Rl::Vector4) -> Rl::Vector4
Rl.vector4_min(v1:Rl::Vector4, v2:Rl::Vector4) -> Rl::Vector4
Rl.vector4_max(v1:Rl::Vector4, v2:Rl::Vector4) -> Rl::Vector4
Rl.vector4_lerp(v1:Rl::Vector4, v2:Rl::Vector4, amount:Float) -> Rl::Vector4
Rl.vector4_move_towards(v:Rl::Vector4, target:Rl::Vector4, max_distance:Float) -> Rl::Vector4
Rl.vector4_invert(v:Rl::Vector4) -> Rl::Vector4
Rl.vector4_equals(p:Rl::Vector4, q:Rl::Vector4) -> Integer
Rl.matrix_determinant(mat:Rl::Matrix) -> Float
Rl.matrix_trace(mat:Rl::Matrix) -> Float
Rl.matrix_transpose(mat:Rl::Matrix) -> Rl::Matrix
Rl.matrix_invert(mat:Rl::Matrix) -> Rl::Matrix
Rl.matrix_identity -> Rl::Matrix
Rl.matrix_add(left:Rl::Matrix, right:Rl::Matrix) -> Rl::Matrix
Rl.matrix_subtract(left:Rl::Matrix, right:Rl::Matrix) -> Rl::Matrix
Rl.matrix_multiply(left:Rl::Matrix, right:Rl::Matrix) -> Rl::Matrix
Rl.matrix_multiply_value(left:Rl::Matrix, value:Float) -> Rl::Matrix
Rl.matrix_translate(x:Float, y:Float, z:Float) -> Rl::Matrix
Rl.matrix_rotate(axis:Rl::Vector3, angle:Float) -> Rl::Matrix
Rl.matrix_rotate_x(angle:Float) -> Rl::Matrix
Rl.matrix_rotate_y(angle:Float) -> Rl::Matrix
Rl.matrix_rotate_z(angle:Float) -> Rl::Matrix
Rl.matrix_rotate_xyz(angle:Rl::Vector3) -> Rl::Matrix
Rl.matrix_rotate_zyx(angle:Rl::Vector3) -> Rl::Matrix
Rl.matrix_scale(x:Float, y:Float, z:Float) -> Rl::Matrix
Rl.matrix_frustum(left:Float, right:Float, bottom:Float, top:Float, near_plane:Float, far_plane:Float) -> Rl::Matrix
Rl.matrix_perspective(fov_y:Float, aspect:Float, near_plane:Float, far_plane:Float) -> Rl::Matrix
Rl.matrix_ortho(left:Float, right:Float, bottom:Float, top:Float, near_plane:Float, far_plane:Float) -> Rl::Matrix
Rl.matrix_look_at(eye:Rl::Vector3, target:Rl::Vector3, up:Rl::Vector3) -> Rl::Matrix
Rl.quaternion_add(q1:Rl::Vector4, q2:Rl::Vector4) -> Rl::Vector4
Rl.quaternion_add_value(q:Rl::Vector4, add:Float) -> Rl::Vector4
Rl.quaternion_subtract(q1:Rl::Vector4, q2:Rl::Vector4) -> Rl::Vector4
Rl.quaternion_subtract_value(q:Rl::Vector4, sub:Float) -> Rl::Vector4
Rl.quaternion_identity -> Rl::Vector4
Rl.quaternion_length(q:Rl::Vector4) -> Float
Rl.quaternion_normalize(q:Rl::Vector4) -> Rl::Vector4
Rl.quaternion_invert(q:Rl::Vector4) -> Rl::Vector4
Rl.quaternion_multiply(q1:Rl::Vector4, q2:Rl::Vector4) -> Rl::Vector4
Rl.quaternion_scale(q:Rl::Vector4, mul:Float) -> Rl::Vector4
Rl.quaternion_divide(q1:Rl::Vector4, q2:Rl::Vector4) -> Rl::Vector4
Rl.quaternion_lerp(q1:Rl::Vector4, q2:Rl::Vector4, amount:Float) -> Rl::Vector4
Rl.quaternion_nlerp(q1:Rl::Vector4, q2:Rl::Vector4, amount:Float) -> Rl::Vector4
Rl.quaternion_slerp(q1:Rl::Vector4, q2:Rl::Vector4, amount:Float) -> Rl::Vector4
Rl.quaternion_cubic_hermite_spline(q1:Rl::Vector4, out_tangent1:Rl::Vector4, q2:Rl::Vector4, in_tangent2:Rl::Vector4, t:Float) -> Rl::Vector4
Rl.quaternion_from_vector3_to_vector3(from:Rl::Vector3, to:Rl::Vector3) -> Rl::Vector4
Rl.quaternion_from_matrix(mat:Rl::Matrix) -> Rl::Vector4
Rl.quaternion_to_matrix(q:Rl::Vector4) -> Rl::Matrix
Rl.quaternion_from_axis_angle(axis:Rl::Vector3, angle:Float) -> Rl::Vector4
Rl.quaternion_from_euler(pitch:Float, yaw:Float, roll:Float) -> Rl::Vector4
Rl.quaternion_to_euler(q:Rl::Vector4) -> Rl::Vector3
Rl.quaternion_transform(q:Rl::Vector4, mat:Rl::Matrix) -> Rl::Vector4
Rl.quaternion_equals(p:Rl::Vector4, q:Rl::Vector4) -> Integer
Rl.matrix_compose(translation:Rl::Vector3, rotation:Rl::Vector4, scale:Rl::Vector3) -> Rl::Matrix
Rl.matrix_decompose(mat:Rl::Matrix, translation:Rl::Vector3, rotation:Rl::Vector4, scale:Rl::Vector3)
```

## Structs
Constructor args are positional in the order shown; every listed field has
`obj.field` (read) and `obj.field=` (write). Pointer/array fields (if any)
are omitted (not accessible).
```ruby
Rl::Vector2.new(x:Float, y:Float)  # Vector2, 2 components
Rl::Vector3.new(x:Float, y:Float, z:Float)  # Vector3, 3 components
Rl::Vector4.new(x:Float, y:Float, z:Float, w:Float)  # Vector4, 4 components
Rl::Matrix.new(m0:Float, m4:Float, m8:Float, m12:Float, m1:Float, m5:Float, m9:Float, m13:Float, m2:Float, m6:Float, m10:Float, m14:Float, m3:Float, m7:Float, m11:Float, m15:Float)  # Matrix, 4x4 components, column major, OpenGL style, right-handed
Rl::Color.new(r:Integer, g:Integer, b:Integer, a:Integer)  # Color, 4 components, R8G8B8A8 (32bit)
Rl::Rectangle.new(x:Float, y:Float, width:Float, height:Float)  # Rectangle, 4 components
Rl::Image.new(width:Integer, height:Integer, mipmaps:Integer, format:Integer)  # Image, pixel data stored in CPU memory (RAM)
Rl::Texture.new(id:Integer, width:Integer, height:Integer, mipmaps:Integer, format:Integer)  # Texture, tex data stored in GPU memory (VRAM)
Rl::RenderTexture.new(id:Integer, texture:Rl::Texture, depth:Rl::Texture)  # RenderTexture, fbo for texture rendering
Rl::NPatchInfo.new(source:Rl::Rectangle, left:Integer, top:Integer, right:Integer, bottom:Integer, layout:Integer)  # NPatchInfo, n-patch layout info
Rl::GlyphInfo.new(value:Integer, offsetX:Integer, offsetY:Integer, advanceX:Integer, image:Rl::Image)  # GlyphInfo, font characters glyphs info
Rl::Font.new(baseSize:Integer, glyphCount:Integer, glyphPadding:Integer, texture:Rl::Texture, recs:Rl::Rectangle, glyphs:Rl::GlyphInfo)  # Font, font texture and GlyphInfo array data
Rl::Camera3D.new(position:Rl::Vector3, target:Rl::Vector3, up:Rl::Vector3, fovy:Float, projection:Integer)  # Camera, defines position/orientation in 3d space
Rl::Camera2D.new(offset:Rl::Vector2, target:Rl::Vector2, rotation:Float, zoom:Float)  # Camera2D, defines position/orientation in 2d space
Rl::Mesh.new(vertexCount:Integer, triangleCount:Integer, boneCount:Integer, vaoId:Integer)  # Mesh, vertex data and vao/vbo
Rl::Shader.new(id:Integer)  # Shader
Rl::MaterialMap.new(texture:Rl::Texture, color:Rl::Color, value:Float)  # MaterialMap
Rl::Material.new(shader:Rl::Shader, maps:Rl::MaterialMap, params:Integer)  # Material, includes shader and maps
Rl::Transform.new(translation:Rl::Vector3, rotation:Rl::Vector4, scale:Rl::Vector3)  # Transform, vertex transformation data
Rl::BoneInfo.new(name:Integer, parent:Integer)  # Bone, skeletal animation bone
Rl::ModelSkeleton.new(boneCount:Integer, bones:Rl::BoneInfo, bindPose:Integer)  # Skeleton, animation bones hierarchy
Rl::Model.new(transform:Rl::Matrix, meshCount:Integer, materialCount:Integer, meshes:Rl::Mesh, materials:Rl::Material, skeleton:Rl::ModelSkeleton, currentPose:Integer, boneMatrices:Rl::Matrix)  # Model, meshes, materials and animation data
Rl::ModelAnimation.new(name:Integer, boneCount:Integer, keyframeCount:Integer)  # ModelAnimation, contains a full animation sequence
Rl::Ray.new(position:Rl::Vector3, direction:Rl::Vector3)  # Ray, ray for raycasting
Rl::RayCollision.new(hit:Boolean, distance:Float, point:Rl::Vector3, normal:Rl::Vector3)  # RayCollision, ray hit information
Rl::BoundingBox.new(min:Rl::Vector3, max:Rl::Vector3)  # BoundingBox
Rl::Wave.new(frameCount:Integer, sampleRate:Integer, sampleSize:Integer, channels:Integer)  # Wave, audio wave data
Rl::AudioStream.new(sampleRate:Integer, sampleSize:Integer, channels:Integer)  # AudioStream, custom audio stream
Rl::Sound.new(stream:Rl::AudioStream, frameCount:Integer)  # Sound
Rl::Music.new(stream:Rl::AudioStream, frameCount:Integer, looping:Boolean, ctxType:Integer)  # Music, audio stream, anything longer than ~10 seconds should be streamed
Rl::VrDeviceInfo.new(hResolution:Integer, vResolution:Integer, hScreenSize:Float, vScreenSize:Float, eyeToScreenDistance:Float, lensSeparationDistance:Float, interpupillaryDistance:Float, lensDistortionValues:Integer, chromaAbCorrection:Integer)  # VrDeviceInfo, Head-Mounted-Display device parameters
Rl::VrStereoConfig.new(projection:Integer, viewOffset:Integer, leftLensCenter:Integer, rightLensCenter:Integer, leftScreenCenter:Integer, rightScreenCenter:Integer, scale:Integer, scaleIn:Integer)  # VrStereoConfig, VR stereo rendering configuration for simulator
Rl::FilePathList.new(count:Integer)  # File path list
Rl::AutomationEvent.new(frame:Integer, type:Integer, params:Integer)  # Automation event
Rl::AutomationEventList.new(capacity:Integer, count:Integer, events:Rl::AutomationEvent)  # Automation event list
```
Aliases (same class): Quaternion=Vector4, Texture2D=Texture, TextureCubemap=Texture, RenderTexture2D=RenderTexture, Camera=Camera3D, ModelAnimPose=Transform

## Enums (constants under Rl::)
```
# ConfigFlags: System/Window config flags
FLAG_VSYNC_HINT=64 FLAG_FULLSCREEN_MODE=2 FLAG_WINDOW_RESIZABLE=4 FLAG_WINDOW_UNDECORATED=8 FLAG_WINDOW_HIDDEN=128 FLAG_WINDOW_MINIMIZED=512 FLAG_WINDOW_MAXIMIZED=1024 FLAG_WINDOW_UNFOCUSED=2048 FLAG_WINDOW_TOPMOST=4096 FLAG_WINDOW_ALWAYS_RUN=256 FLAG_WINDOW_TRANSPARENT=16 FLAG_WINDOW_HIGHDPI=8192 FLAG_WINDOW_MOUSE_PASSTHROUGH=16384 FLAG_BORDERLESS_WINDOWED_MODE=32768 FLAG_MSAA_4X_HINT=32 FLAG_INTERLACED_HINT=65536
# TraceLogLevel: Trace log level
LOG_ALL=0 LOG_TRACE=1 LOG_DEBUG=2 LOG_INFO=3 LOG_WARNING=4 LOG_ERROR=5 LOG_FATAL=6 LOG_NONE=7
# KeyboardKey: Keyboard keys (US keyboard layout)
KEY_NULL=0 KEY_APOSTROPHE=39 KEY_COMMA=44 KEY_MINUS=45 KEY_PERIOD=46 KEY_SLASH=47 KEY_ZERO=48 KEY_ONE=49 KEY_TWO=50 KEY_THREE=51 KEY_FOUR=52 KEY_FIVE=53 KEY_SIX=54 KEY_SEVEN=55 KEY_EIGHT=56 KEY_NINE=57 KEY_SEMICOLON=59 KEY_EQUAL=61 KEY_A=65 KEY_B=66 KEY_C=67 KEY_D=68 KEY_E=69 KEY_F=70 KEY_G=71 KEY_H=72 KEY_I=73 KEY_J=74 KEY_K=75 KEY_L=76 KEY_M=77 KEY_N=78 KEY_O=79 KEY_P=80 KEY_Q=81 KEY_R=82 KEY_S=83 KEY_T=84 KEY_U=85 KEY_V=86 KEY_W=87 KEY_X=88 KEY_Y=89 KEY_Z=90 KEY_LEFT_BRACKET=91 KEY_BACKSLASH=92 KEY_RIGHT_BRACKET=93 KEY_GRAVE=96 KEY_SPACE=32 KEY_ESCAPE=256 KEY_ENTER=257 KEY_TAB=258 KEY_BACKSPACE=259 KEY_INSERT=260 KEY_DELETE=261 KEY_RIGHT=262 KEY_LEFT=263 KEY_DOWN=264 KEY_UP=265 KEY_PAGE_UP=266 KEY_PAGE_DOWN=267 KEY_HOME=268 KEY_END=269 KEY_CAPS_LOCK=280 KEY_SCROLL_LOCK=281 KEY_NUM_LOCK=282 KEY_PRINT_SCREEN=283 KEY_PAUSE=284 KEY_F1=290 KEY_F2=291 KEY_F3=292 KEY_F4=293 KEY_F5=294 KEY_F6=295 KEY_F7=296 KEY_F8=297 KEY_F9=298 KEY_F10=299 KEY_F11=300 KEY_F12=301 KEY_LEFT_SHIFT=340 KEY_LEFT_CONTROL=341 KEY_LEFT_ALT=342 KEY_LEFT_SUPER=343 KEY_RIGHT_SHIFT=344 KEY_RIGHT_CONTROL=345 KEY_RIGHT_ALT=346 KEY_RIGHT_SUPER=347 KEY_KB_MENU=348 KEY_KP_0=320 KEY_KP_1=321 KEY_KP_2=322 KEY_KP_3=323 KEY_KP_4=324 KEY_KP_5=325 KEY_KP_6=326 KEY_KP_7=327 KEY_KP_8=328 KEY_KP_9=329 KEY_KP_DECIMAL=330 KEY_KP_DIVIDE=331 KEY_KP_MULTIPLY=332 KEY_KP_SUBTRACT=333 KEY_KP_ADD=334 KEY_KP_ENTER=335 KEY_KP_EQUAL=336 KEY_BACK=4 KEY_MENU=5 KEY_VOLUME_UP=24 KEY_VOLUME_DOWN=25
# MouseButton: Mouse buttons
MOUSE_BUTTON_LEFT=0 MOUSE_BUTTON_RIGHT=1 MOUSE_BUTTON_MIDDLE=2 MOUSE_BUTTON_SIDE=3 MOUSE_BUTTON_EXTRA=4 MOUSE_BUTTON_FORWARD=5 MOUSE_BUTTON_BACK=6
# MouseCursor: Mouse cursor
MOUSE_CURSOR_DEFAULT=0 MOUSE_CURSOR_ARROW=1 MOUSE_CURSOR_IBEAM=2 MOUSE_CURSOR_CROSSHAIR=3 MOUSE_CURSOR_POINTING_HAND=4 MOUSE_CURSOR_RESIZE_EW=5 MOUSE_CURSOR_RESIZE_NS=6 MOUSE_CURSOR_RESIZE_NWSE=7 MOUSE_CURSOR_RESIZE_NESW=8 MOUSE_CURSOR_RESIZE_ALL=9 MOUSE_CURSOR_NOT_ALLOWED=10
# GamepadButton: Gamepad buttons
GAMEPAD_BUTTON_UNKNOWN=0 GAMEPAD_BUTTON_LEFT_FACE_UP=1 GAMEPAD_BUTTON_LEFT_FACE_RIGHT=2 GAMEPAD_BUTTON_LEFT_FACE_DOWN=3 GAMEPAD_BUTTON_LEFT_FACE_LEFT=4 GAMEPAD_BUTTON_RIGHT_FACE_UP=5 GAMEPAD_BUTTON_RIGHT_FACE_RIGHT=6 GAMEPAD_BUTTON_RIGHT_FACE_DOWN=7 GAMEPAD_BUTTON_RIGHT_FACE_LEFT=8 GAMEPAD_BUTTON_LEFT_TRIGGER_1=9 GAMEPAD_BUTTON_LEFT_TRIGGER_2=10 GAMEPAD_BUTTON_RIGHT_TRIGGER_1=11 GAMEPAD_BUTTON_RIGHT_TRIGGER_2=12 GAMEPAD_BUTTON_MIDDLE_LEFT=13 GAMEPAD_BUTTON_MIDDLE=14 GAMEPAD_BUTTON_MIDDLE_RIGHT=15 GAMEPAD_BUTTON_LEFT_THUMB=16 GAMEPAD_BUTTON_RIGHT_THUMB=17
# GamepadAxis: Gamepad axes
GAMEPAD_AXIS_LEFT_X=0 GAMEPAD_AXIS_LEFT_Y=1 GAMEPAD_AXIS_RIGHT_X=2 GAMEPAD_AXIS_RIGHT_Y=3 GAMEPAD_AXIS_LEFT_TRIGGER=4 GAMEPAD_AXIS_RIGHT_TRIGGER=5
# MaterialMapIndex: Material map index
MATERIAL_MAP_ALBEDO=0 MATERIAL_MAP_METALNESS=1 MATERIAL_MAP_NORMAL=2 MATERIAL_MAP_ROUGHNESS=3 MATERIAL_MAP_OCCLUSION=4 MATERIAL_MAP_EMISSION=5 MATERIAL_MAP_HEIGHT=6 MATERIAL_MAP_CUBEMAP=7 MATERIAL_MAP_IRRADIANCE=8 MATERIAL_MAP_PREFILTER=9 MATERIAL_MAP_BRDF=10
# ShaderLocationIndex: Shader location index
SHADER_LOC_VERTEX_POSITION=0 SHADER_LOC_VERTEX_TEXCOORD01=1 SHADER_LOC_VERTEX_TEXCOORD02=2 SHADER_LOC_VERTEX_NORMAL=3 SHADER_LOC_VERTEX_TANGENT=4 SHADER_LOC_VERTEX_COLOR=5 SHADER_LOC_MATRIX_MVP=6 SHADER_LOC_MATRIX_VIEW=7 SHADER_LOC_MATRIX_PROJECTION=8 SHADER_LOC_MATRIX_MODEL=9 SHADER_LOC_MATRIX_NORMAL=10 SHADER_LOC_VECTOR_VIEW=11 SHADER_LOC_COLOR_DIFFUSE=12 SHADER_LOC_COLOR_SPECULAR=13 SHADER_LOC_COLOR_AMBIENT=14 SHADER_LOC_MAP_ALBEDO=15 SHADER_LOC_MAP_METALNESS=16 SHADER_LOC_MAP_NORMAL=17 SHADER_LOC_MAP_ROUGHNESS=18 SHADER_LOC_MAP_OCCLUSION=19 SHADER_LOC_MAP_EMISSION=20 SHADER_LOC_MAP_HEIGHT=21 SHADER_LOC_MAP_CUBEMAP=22 SHADER_LOC_MAP_IRRADIANCE=23 SHADER_LOC_MAP_PREFILTER=24 SHADER_LOC_MAP_BRDF=25 SHADER_LOC_VERTEX_BONEIDS=26 SHADER_LOC_VERTEX_BONEWEIGHTS=27 SHADER_LOC_MATRIX_BONETRANSFORMS=28 SHADER_LOC_VERTEX_INSTANCETRANSFORM=29
# ShaderUniformDataType: Shader uniform data type
SHADER_UNIFORM_FLOAT=0 SHADER_UNIFORM_VEC2=1 SHADER_UNIFORM_VEC3=2 SHADER_UNIFORM_VEC4=3 SHADER_UNIFORM_INT=4 SHADER_UNIFORM_IVEC2=5 SHADER_UNIFORM_IVEC3=6 SHADER_UNIFORM_IVEC4=7 SHADER_UNIFORM_UINT=8 SHADER_UNIFORM_UIVEC2=9 SHADER_UNIFORM_UIVEC3=10 SHADER_UNIFORM_UIVEC4=11 SHADER_UNIFORM_SAMPLER2D=12
# ShaderAttributeDataType: Shader attribute data types
SHADER_ATTRIB_FLOAT=0 SHADER_ATTRIB_VEC2=1 SHADER_ATTRIB_VEC3=2 SHADER_ATTRIB_VEC4=3
# PixelFormat: Pixel formats
PIXELFORMAT_UNCOMPRESSED_GRAYSCALE=1 PIXELFORMAT_UNCOMPRESSED_GRAY_ALPHA=2 PIXELFORMAT_UNCOMPRESSED_R5G6B5=3 PIXELFORMAT_UNCOMPRESSED_R8G8B8=4 PIXELFORMAT_UNCOMPRESSED_R5G5B5A1=5 PIXELFORMAT_UNCOMPRESSED_R4G4B4A4=6 PIXELFORMAT_UNCOMPRESSED_R8G8B8A8=7 PIXELFORMAT_UNCOMPRESSED_R32=8 PIXELFORMAT_UNCOMPRESSED_R32G32B32=9 PIXELFORMAT_UNCOMPRESSED_R32G32B32A32=10 PIXELFORMAT_UNCOMPRESSED_R16=11 PIXELFORMAT_UNCOMPRESSED_R16G16B16=12 PIXELFORMAT_UNCOMPRESSED_R16G16B16A16=13 PIXELFORMAT_COMPRESSED_DXT1_RGB=14 PIXELFORMAT_COMPRESSED_DXT1_RGBA=15 PIXELFORMAT_COMPRESSED_DXT3_RGBA=16 PIXELFORMAT_COMPRESSED_DXT5_RGBA=17 PIXELFORMAT_COMPRESSED_ETC1_RGB=18 PIXELFORMAT_COMPRESSED_ETC2_RGB=19 PIXELFORMAT_COMPRESSED_ETC2_EAC_RGBA=20 PIXELFORMAT_COMPRESSED_PVRT_RGB=21 PIXELFORMAT_COMPRESSED_PVRT_RGBA=22 PIXELFORMAT_COMPRESSED_ASTC_4x4_RGBA=23 PIXELFORMAT_COMPRESSED_ASTC_8x8_RGBA=24
# TextureFilter: Texture parameters: filter mode
TEXTURE_FILTER_POINT=0 TEXTURE_FILTER_BILINEAR=1 TEXTURE_FILTER_TRILINEAR=2 TEXTURE_FILTER_ANISOTROPIC_4X=3 TEXTURE_FILTER_ANISOTROPIC_8X=4 TEXTURE_FILTER_ANISOTROPIC_16X=5
# TextureWrap: Texture parameters: wrap mode
TEXTURE_WRAP_REPEAT=0 TEXTURE_WRAP_CLAMP=1 TEXTURE_WRAP_MIRROR_REPEAT=2 TEXTURE_WRAP_MIRROR_CLAMP=3
# CubemapLayout: Cubemap layouts
CUBEMAP_LAYOUT_AUTO_DETECT=0 CUBEMAP_LAYOUT_LINE_VERTICAL=1 CUBEMAP_LAYOUT_LINE_HORIZONTAL=2 CUBEMAP_LAYOUT_CROSS_THREE_BY_FOUR=3 CUBEMAP_LAYOUT_CROSS_FOUR_BY_THREE=4
# FontType: Font type, defines generation method
FONT_DEFAULT=0 FONT_BITMAP=1 FONT_SDF=2
# BlendMode: Color blending modes (pre-defined)
BLEND_ALPHA=0 BLEND_ADDITIVE=1 BLEND_MULTIPLIED=2 BLEND_ADD_COLORS=3 BLEND_SUBTRACT_COLORS=4 BLEND_ALPHA_PREMULTIPLY=5 BLEND_CUSTOM=6 BLEND_CUSTOM_SEPARATE=7
# Gesture: Gesture
GESTURE_NONE=0 GESTURE_TAP=1 GESTURE_DOUBLETAP=2 GESTURE_HOLD=4 GESTURE_DRAG=8 GESTURE_SWIPE_RIGHT=16 GESTURE_SWIPE_LEFT=32 GESTURE_SWIPE_UP=64 GESTURE_SWIPE_DOWN=128 GESTURE_PINCH_IN=256 GESTURE_PINCH_OUT=512
# CameraMode: Camera system modes
CAMERA_CUSTOM=0 CAMERA_FREE=1 CAMERA_ORBITAL=2 CAMERA_FIRST_PERSON=3 CAMERA_THIRD_PERSON=4
# CameraProjection: Camera projection
CAMERA_PERSPECTIVE=0 CAMERA_ORTHOGRAPHIC=1
# NPatchLayout: N-patch layout
NPATCH_NINE_PATCH=0 NPATCH_THREE_PATCH_VERTICAL=1 NPATCH_THREE_PATCH_HORIZONTAL=2
```

## Other constants under Rl::
```
# Colors (Rl::Color constants)
LIGHTGRAY GRAY DARKGRAY YELLOW GOLD ORANGE PINK RED MAROON GREEN LIME DARKGREEN SKYBLUE BLUE DARKBLUE PURPLE VIOLET DARKPURPLE BEIGE BROWN DARKBROWN WHITE BLACK BLANK MAGENTA RAYWHITE
# Numeric
RAYLIB_VERSION_MAJOR=6 RAYLIB_VERSION_MINOR=0 RAYLIB_VERSION_PATCH=0 PI=3.141592653589793
# String
RAYLIB_VERSION="6.0"
```

## RmlUi (HTML/CSS UI; call Rml.init AFTER Rl.init_window)
```ruby
# setup / lifecycle
Rml.init                                   # -> nil   (inits RmlUi + rlgl backend)
Rml.load_font(path:String, fallback:false) # register .ttf
Rml.shutdown
ctx = Rml::Context.new(name:String, width:Integer=screen_w, height:Integer=screen_h)
ctx.resize(width:Integer, height:Integer)
ctx.dimensions = Rl::Vector2

# per-frame: process_input before block, update+render after (exception-safe)
ctx.frame { ...mutate ui... }
ctx.process_input ; ctx.update ; ctx.render   # manual equivalent

# documents
doc = ctx.load_document(path:String) { |doc| ... }  # -> Rml::Document
ctx.document(id:String)        # -> Rml::Element (already-loaded lookup) | nil
ctx.num_documents              # -> Integer
doc.show ; doc.hide ; doc.close ; doc.pull_to_front ; doc.push_to_back
doc.title ; doc.title = String

# Rml::Element (Document is a subclass)
el[name]            # get attribute -> String|nil ;  el[name] = value
el.attribute(name) ; el.set_attribute(name, v) ; el.has_attribute?(name) ; el.remove_attribute(name)
el.id ; el.id = v ; el.tag_name
el.inner_rml ; el.inner_rml = html ; el.text ; el.text = s
el.add_class(c) ; el.remove_class(c) ; el.set_class(c, bool) ; el.class_set?(c)
el.set_property("color","red") ; el.property(name) ; el.remove_property(name)
el.focus ; el.blur ; el.click ; el.scroll_into_view(align_top=true) ; el.visible?
el.element(id)              # alias get_element_by_id -> Element|nil
el.query_selector(sel) ; el.query_selector_all(sel) ; el.elements_by_tag(tag)
el.parent ; el.child_count ; el.child(i) ; el.children ; el.owner_document
el.client_width ; el.client_height ; el.offset_left ; el.offset_top ; el.absolute_left ; el.absolute_top
el.on(:click) { |event| ... }     # event types: click, mouseover, change, submit, ...

# Rml::Event (passed to el.on)
ev.type ; ev.target ; ev.current ; ev.stop_propagation ; ev.stop_immediate_propagation
ev[key] -> Float ; ev.param(key) -> Float ; ev.param_str(key) -> String ; ev.mouse_x ; ev.mouse_y

# MVC data model (binds Ruby to {{vars}} / data-* in RML). Create BEFORE load_document.
m = ctx.data_model(name:String) do |m|
  m.bind(:score) { game.score }   # one-way computed (read each frame)
  m.value(:hp, 100)               # two-way scalar
  m.event(:reset) { game.reset! } # controller: rml `data-event-click="reset()"`
end                               # block form finishes it automatically
m[:hp] ; m[:hp] = 80              # read / write+dirty
m.dirty(:score, ...) ; m.dirty_all   # re-evaluate bound vars after state changes
```

## Flecs (ECS, module `Flecs::`)
Entity Component System. Components are real C structs declared at runtime from
a meta descriptor string and (de)serialized to/from Ruby Hashes. Works
identically on desktop and web. Entities/components are integer ids wrapped in
Flecs::Entity / Flecs::Component (use them anywhere an id is expected).
```ruby
world = Flecs::World.new                       # owns the ecs_world_t (freed by GC)

# Components: a meta struct descriptor (C type syntax). Returns Flecs::Component.
pos = world.struct("Position", "{float x; float y;}")
vel = world.struct("Velocity", "{float x; float y;}")
# supported member types: bool, char, [iu]8/16/32/64, f32/f64, uptr/iptr,
# string (char*), entity, nested structs, inline arrays.
npc = world.tag("Npc")                          # dataless id -> Flecs::Component

# Entities (Flecs::Entity)
e = world.entity("player")                      # name optional
e = world.entity                                # anonymous
world.lookup("player")                          # -> Flecs::Entity | nil
e.id ; e.to_i ; e.name ; e.name = "p2" ; e.alive? ; e.delete

# Components on entities (Hash <-> struct)
e.set(pos, x: 1.0, y: 2.0)                       # kwargs or e.set(pos, {x:1,y:2})
e.get(pos)            # -> {x: 1.0, y: 2.0} | nil
e.add(npc) ; e.remove(npc) ; e.has?(npc)        # tags or components
e.set(pos, x: 0, y: 0).add(npc)                 # chainable

# Systems: run each progress() during a phase. Block gets |entity_id, *comp_hashes|
# in the order of `with:`; mutations to the component Hashes are written back.
world.system("Move", with: [pos, vel]) do |id, p, v|
  p[:x] += v[:x]; p[:y] += v[:y]
end
world.progress(dt = 0.0)   # -> Boolean (false = quit); runs all systems once

# Ad-hoc queries (cached) -> Flecs::Query (Enumerable)
q = world.query(pos, vel)
q.each { |id, p, v| ... }                        # same writeback semantics

# phases: Flecs::ON_LOAD, Flecs::PRE_UPDATE, Flecs::ON_UPDATE (default), Flecs::ON_START
```
NOTE: the system/query block receives the entity as an **Integer id** (not a
Flecs::Entity) for speed; wrap with `world.entity_for(id)` if you need methods —
or just use ids. Component data is delivered as Hashes; mutate them in place.
Multithreaded systems are NOT exposed (single-threaded `progress` only; this is
also the only mode that works on the wasm/web build).

## Jolt Physics (3D, module `Jolt::`)
Rigid-body 3D physics via the joltc C API. Vectors accept Arrays or Rl::Vector3
and are returned as Rl::Vector3/Vector4. Single-threaded `step` (identical on
desktop and web). Full spec: docs/API_SPEC_JOLT.md.
```ruby
world = Jolt::World.new(gravity: [0, -9.81, 0], max_bodies: 10240)
world.gravity = [0, -20, 0]
world.step(dt = 1.0/60.0, collision_steps: 1)   # advance; alias: update
world.optimize_broad_phase                       # once after bulk-adding bodies

# shapes (reusable) -> Jolt::Shape
Jolt.box(width, height, depth)        # FULL dimensions (not half-extents)
Jolt.sphere(radius)
Jolt.capsule(half_height, radius)     # half-height of cylinder section
Jolt.cylinder(half_height, radius)
Jolt.convex_hull(points)              # Array of [x,y,z]
Jolt.mesh(vertices)                   # triangle soup (3 verts/tri); STATIC bodies only

# bodies -> Jolt::Body. motion: Jolt::STATIC | KINEMATIC | DYNAMIC
b = world.body(shape: Jolt.sphere(0.5), position: [0,10,0], rotation: [0,0,0,1],
               motion: Jolt::DYNAMIC, restitution: 0.0, friction: 0.2, activate: true,
               velocity: nil, user_data: nil, mass: nil, linear_damping: 0.05,
               angular_damping: 0.05, ccd: false, sensor: false)  # alias: add_body
b.sensor = true ; b.ccd = true   # also settable at runtime
b.id ; b.position -> Rl::Vector3 ; b.center_of_mass ; b.rotation -> Rl::Vector4
b.position = [x,y,z]
b.set_transform(position:, rotation: nil, activate: true)
b.linear_velocity ; b.linear_velocity = [x,y,z]
b.angular_velocity ; b.angular_velocity = [x,y,z]
b.apply_force(v) ; b.apply_impulse(v) ; b.apply_torque(v)   # chainable
b.active? ; b.activate ; b.deactivate ; b.remove
b.user_data ; b.user_data = entity_id        # 64-bit tag (map collisions -> game objs)
b.motion_type ; b.motion_type = Jolt::KINEMATIC ; b.set_motion_type(mt, activate: true)
b.friction = 0.8 ; b.restitution = 0.9 ; b.gravity_factor = 0.0

# queries
hit = world.raycast([0,10,0], [0,-20,0])     # -> Jolt::RayHit | nil
hit.body_id ; hit.body ; hit.fraction ; hit.point -> Rl::Vector3 ; hit.normal -> Rl::Vector3
world.overlap_point([x,y,z]) -> Array<Jolt::Body>   # bodies containing a point

# collision events (began this step) -> Array<Jolt::Contact>; ended -> ContactEnd
world.contacts.each do |c|
  c.body_a_id ; c.body_b_id ; c.body_a ; c.body_b
  c.point -> Rl::Vector3 ; c.normal -> Rl::Vector3
  c.involves?(b) ; other = c.other(b)        # the other body in the contact
end
world.contacts_ended.each { |c| c.involves?(zone) ; c.other(zone) }  # stopped touching
# sensor bodies (sensor: true) + contacts/contacts_ended = trigger volumes (enter/leave)

# constraints / joints (return Jolt::Constraint; joint.remove to detach).
# The WORLD retains constraints + ragdolls, so a dropped handle still stays
# alive (a GC'd Constraint/Ragdoll would otherwise detach itself). Use .remove.
world.weld(a, b)                                   # rigid weld
world.ball_joint(a, b, point)                      # point-to-point
world.distance_joint(a, b, pa, pb, min: 0, max: 2) # rope/rod
world.hinge(a, b, point, axis, min_deg: -90, max_deg: 90)  # door
world.slider(a, b, point, axis, min: -2, max: 2)   # piston
world.cone(a, b, point, axis, half_angle_deg: 30)  # swing/twist limit

# character controller (kinematic capsule; stair-step + slope) -> Jolt::Character
ch = world.character(shape: Jolt.capsule(0.6, 0.3), position: [0,2,0],
                     max_slope_deg: 45, mass: 70)
# per frame: set velocity (apply gravity/jump yourself), then update + step
v = ch.velocity
vy = ch.on_ground? ? (jump ? 6.0 : 0.0) : v.y - 20.0 * dt
ch.velocity = [input_x * 5, vy, input_z * 5]
ch.update(dt) ; world.step(dt)
ch.position -> Rl::Vector3 ; ch.position = [x,y,z] ; ch.on_ground?
ch.ground_state # :on_ground|:on_steep|:not_supported|:in_air ; ch.ground_normal ; ch.supported?
ch.max_strength = 6000 ; ch.mass = 70   # push force vs dynamic bodies / collision mass
# ride moving platforms: a KINEMATIC body whose velocity the character inherits
ch.ground_velocity -> Rl::Vector3   # velocity of the surface underfoot (0 if airborne)
ch.ground_body -> Jolt::Body | nil  # the body it stands on
ch.ride(dt)                         # = update(dt) + inherit a STATIC/KINEMATIC
                                    # platform's velocity (DYNAMIC ground ignored,
                                    # else its reaction to your weight flings you)

# ragdoll: tree of dynamic bodies + swing-twist joints. Parts PARENTS-FIRST.
rd = world.ragdoll(parts: [
  { name: :torso, shape: Jolt.capsule(0.22,0.16), position: [0,4,0], mass: 20 },
  { name: :head,  shape: Jolt.sphere(0.16), position: [0,4.45,0], parent: :torso,
    joint: [0,4.24,0], twist_axis: [0,1,0], plane_axis: [1,0,0],
    cone_deg: 25, plane_deg: 25, twist_min_deg: -25, twist_max_deg: 25 },
], user_data: 0)
rd.body_count ; rd.bodies -> Array<Jolt::Body> ; rd[0] ; rd.activate
rd.bodies.each { |b| b.apply_impulse([fx,fy,fz]) } ; rd.remove
# capsule parts: local axis = Y; draw via
#   Rl.vector3_rotate_by_quaternion([0, half_height, 0], body.rotation)
```
NOTE: STATIC = never moves (floors/walls), KINEMATIC = you move it (infinite
mass), DYNAMIC = simulated; collision layer is derived from motion type.
Use body.user_data to bridge contacts back to game objects (e.g. flecs entity
ids). Not exposed: shape-cast queries, height-field/compound shapes, vehicles,
soft bodies, ragdoll pose/motor driving, custom layers, multithreading.
Determinism is OFF.

## NOT bound (do not call — no Ruby method exists)
These raylib/raymath functions are intentionally unbound (callbacks, raw
pointers/buffers, varargs, or array/string returns). Use Ruby equivalents
(`File`, `format`, arrays, `puts`) or avoid.
```
AttachAudioMixedProcessor, AttachAudioStreamProcessor, CodepointToUTF8, CompressData,
ComputeCRC32, ComputeMD5, ComputeSHA1, ComputeSHA256,
DecodeDataBase64, DecompressData, DetachAudioMixedProcessor, DetachAudioStreamProcessor,
DrawTextCodepoints, EncodeDataBase64, ExportDataAsCode, ExportImageToMemory,
GenImageFontAtlas, GetClipboardImage, GetCodepoint, GetCodepointNext,
GetCodepointPrevious, GetPixelColor, GetWindowHandle, ImageKernelConvolution,
LoadCodepoints, LoadFileData, LoadFontData, LoadFontEx,
LoadFontFromMemory, LoadImageAnim, LoadImageAnimFromMemory, LoadImageColors,
LoadImageFromMemory, LoadImagePalette, LoadMaterials, LoadModelAnimations,
LoadMusicStreamFromMemory, LoadRandomSequence, LoadTextLines, LoadUTF8,
LoadWaveFromMemory, LoadWaveSamples, MatrixToFloatV, MeasureTextCodepoints,
MemAlloc, MemFree, MemRealloc, QuaternionToAxisAngle,
SaveFileData, SetAudioStreamCallback, SetLoadFileDataCallback, SetLoadFileTextCallback,
SetPixelColor, SetSaveFileDataCallback, SetSaveFileTextCallback, SetTraceLogCallback,
TextAppend, TextCopy, TextFormat, TextJoin,
TextSplit, TraceLog, UnloadCodepoints, UnloadFileData,
UnloadFileText, UnloadRandomSequence, UnloadTextLines, UnloadUTF8,
UnloadWaveSamples, UpdateAudioStream, UpdateMeshBuffer, UpdateSound,
UpdateTexture, UpdateTextureRec, Vector3ToFloatV
```

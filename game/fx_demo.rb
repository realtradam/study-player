# raylib-jamstack: FX PIPELINE DEMO — layered two-stage post-processing.
#
#   ./zig-out/bin/game game/fx_demo.rb                       (desktop)
#   web: set web/shell.html Module.arguments to ['game/fx_demo.rb'], rebuild.
#
# Demonstrates Jamstack::FX: a GAME stage (gameplay FX on the 3D world + in-world
# UI, NOT the overlay HUD) and a TOP stage (complete FX over everything incl HUD).
#
#   game + game-rmlui -> game shaders -> top-rmlui -> top shaders -> screen
#
# Runtime toggling — click the checkboxes in the overlay HUD, OR via the eval
# bridge / in-game console (`\`):
#   fx.game_shaders[0].enabled = false   # warp off     -> world un-warps, HUD stays crisp
#   fx.game_shaders[1].enabled = false   # aberration off (colour shift)
#   fx.top_shaders[0].enabled  = false   # vignette off  -> whole frame incl HUD
# The checkboxes mirror the live `enabled` state each frame (so bridge toggles
# also flip the boxes), and clicking a box sets `enabled` — both paths stay in
# sync. CRT is split into warp + aberration + scanlines (each its own pass).

# --------------------------------------------------------------- window + fonts --
W = 720
H = 720
Rl.init_window(W, H, "raylib-jamstack: FX pipeline")
Rl.target_fps = 60

Rml.init
Rml.load_font("game/ui/LatoLatin-Regular.ttf")
Rml.load_font("game/ui/LatoLatin-Bold.ttf")
Rml.load_font("game/ui/MononokiNerdFontMono-Regular.ttf")

# Two RmlUi contexts: in-world UI (game layer) vs screen-space overlay HUD.
# Context dimensions default to the window size (720x720), which MUST equal the
# render-texture size (the RmlUi scissor uses GetScreenHeight() — see fx.rb).
game_ui = Rml::Context.new("game")
top_ui  = Rml::Context.new("overlay")
game_doc = game_ui.load_document("game/ui/fx_game.rml").show
top_doc  = top_ui.load_document("game/ui/fx_overlay.rml").show
game_rot = game_doc.element("game-rot")
ovr_fps  = top_doc.element("ovr-fps")

# Expose the game binding so the eval bridge / in-game console can reach `fx`.
Jamstack::Bridge.set_binding(binding)

# --------------------------------------------------------- the FX pipeline --
fx = Jamstack::FX::Pipeline.new(W, H)
# GAME stage: gameplay FX on the world + in-world UI, NOT the overlay HUD.
# CRT is split into independent components so each can be toggled separately;
# they chain as ping-pong passes (warp -> aberration -> aberration_cmy -> scanlines).
fx.game_shaders << Jamstack::FX::Pass.new("warp",       Jamstack::FX::WARP,       intensity: 1.0)
fx.game_shaders << Jamstack::FX::Pass.new("aberration", Jamstack::FX::ABERRATION, intensity: 0.8)
fx.game_shaders << Jamstack::FX::Pass.new("aberration_cmy", Jamstack::FX::ABERRATION_CMY, intensity: 0.8)
fx.game_shaders << Jamstack::FX::Pass.new("scanlines",  Jamstack::FX::SCANLINES,  intensity: 0.6)
# TOP stage: complete FX over everything (incl the overlay HUD).
fx.top_shaders  << Jamstack::FX::Pass.new("vignette",  Jamstack::FX::VIGNETTE,  intensity: 1.0)
fx.top_shaders  << Jamstack::FX::Pass.new("grayscale", Jamstack::FX::GRAYSCALE, intensity: 0.65)
# FXAA anti-aliasing — split into two independent toggles, one per layer:
#  fxaa_game (GAME stage): AA the 3D world + in-world UI, leaves the overlay HUD
#    crisp. Suppressed when fxaa_ui is enabled (the top pass already covers the
#    whole frame, so running both would double-AA the world). REQUIRES bilinear
#    input (Pipeline sets BILINEAR on all render textures).
#  fxaa_ui (TOP stage): AA the whole composited frame (incl the overlay HUD).
# Both share one quality slider (0..1 -> subpix / edgeThreshold / edgeThresholdMin).
# State: game-on + ui-off = world AA'd, HUD crisp. ui-on = whole frame AA'd
#        (game pass suppressed) = exactly the previous single-FXAA behavior.
def fxaa_quality(pass, q)
  pass.extra_uniforms[:subpix]           = 0.25 + q * 0.75
  pass.extra_uniforms[:edgeThreshold]   = 0.333 - q * 0.270   # 0.333 -> 0.063
  pass.extra_uniforms[:edgeThresholdMin] = 0.0833 - q * 0.0521  # 0.0833 -> 0.0312
end
fxaa_game = Jamstack::FX::Pass.new("fxaa_game", Jamstack::FX::FXAA,
        extra_uniforms: { subpix: 0.75, edgeThreshold: 0.166, edgeThresholdMin: 0.0833 })
fxaa_ui   = Jamstack::FX::Pass.new("fxaa_ui", Jamstack::FX::FXAA,
        extra_uniforms: { subpix: 0.75, edgeThreshold: 0.166, edgeThresholdMin: 0.0833 })
fxaa_quality(fxaa_game, 0.6)
fxaa_quality(fxaa_ui, 0.6)
fx.game_shaders << fxaa_game   # runs LAST in the game chain (AA the final world)
fx.top_shaders  << fxaa_ui     # runs LAST in the top chain (AA the whole frame)

# SMAA 1x (Enhanced Subpixel Morphological AA) — mirrors the FXAA split so you
# can A/B them. Two independent toggles (game world / whole frame) + a threshold
# slider. NO suppress / no FXAA-collision check by design — this is for testing
# how SMAA looks alongside FXAA (stacking two spatial AAs is usually redundant,
# but we leave it to the user to compare). SMAA is a 3-pass COMPOSITE effect
# (edge detect -> blend weights -> neighborhood blend) that ducks as a Pass for
# apply_chain; it owns two intermediate render textures + the area/search LUTs.
smaa_game = Jamstack::FX::Smaa.new("smaa_game", W, H, threshold: 0.1)
smaa_ui   = Jamstack::FX::Smaa.new("smaa_ui",   W, H, threshold: 0.1)
fx.game_shaders << smaa_game   # after fxaa_game
fx.top_shaders  << smaa_ui     # after fxaa_ui

# ---- clickable checklist: each checkbox toggles its shader's `enabled`.
# RmlUi checkboxes carry state in the `checked` ATTRIBUTE (vendor
# InputTypeCheckbox.cpp): click toggles it and fires `change`. We read it in the
# handler to set `enabled`; the per-frame sync below writes it back from `enabled`
# so eval-bridge toggles flip the boxes too. Pairs of [checkbox, pass].
chk_warp = top_doc.element("chk-warp")
chk_aber = top_doc.element("chk-aber")
chk_cmy  = top_doc.element("chk-cmy")
chk_scan = top_doc.element("chk-scan")
chk_vig  = top_doc.element("chk-vig")
chk_gray = top_doc.element("chk-gray")
chk_fxg = top_doc.element("chk-fxaa-game")
chk_fxu = top_doc.element("chk-fxaa-ui")
chk_sg  = top_doc.element("chk-smaa-game")
chk_su  = top_doc.element("chk-smaa-ui")
rng_qual = top_doc.element("rng-quality")   # FXAA quality slider (input range)
rng_smaa = top_doc.element("rng-smaa")      # SMAA threshold slider (input range)
chk_pairs = [
  [chk_warp, fx.game_shaders[0]],   # warp           (game stage)
  [chk_aber, fx.game_shaders[1]],   # aberration RGB (game stage)
  [chk_cmy,  fx.game_shaders[2]],   # aberration CMY (game stage)
  [chk_scan, fx.game_shaders[3]],   # scanlines      (game stage)
  [chk_fxg, fx.game_shaders[4]],    # fxaa (world)   (game stage)
  [chk_sg,  fx.game_shaders[5]],    # smaa (world)   (game stage)
  [chk_vig,  fx.top_shaders[0]],    # vignette       (top stage)
  [chk_gray, fx.top_shaders[1]],    # grayscale      (top stage)
  [chk_fxu, fx.top_shaders[2]],     # fxaa (ui/all)  (top stage)
  [chk_su,  fx.top_shaders[3]],     # smaa (ui/all)  (top stage)
]
# the shared FXAA quality slider sets BOTH passes' quality (0..1). RmlUi
# form-control value is read via the [] attribute accessor.
rng_qual.on(:change) { q = rng_qual["value"].to_f; fxaa_quality(fxaa_game, q); fxaa_quality(fxaa_ui, q) }
# SMAA threshold slider (0..1 -> 0.01..0.3). Lower = more edges detected = more
# AA (but more blur). Sets both SMAA passes' threshold uniform (no recompile).
rng_smaa.on(:change) do
  t = 0.01 + rng_smaa["value"].to_f * 0.29
  smaa_game.extra_uniforms[:threshold] = t
  smaa_ui.extra_uniforms[:threshold]   = t
end
chk_pairs.each do |chk, pass|
  chk.on(:change) { pass.enabled = chk.has_attribute?("checked") }
end

# ----------------------------------------------------------- 3D world content --
cam = Rl::Camera3D.new(Rl::Vector3.new(6, 6, 8), Rl::Vector3.new(0, 0, 0),
                       Rl::Vector3.new(0, 1, 0), 50.0, Rl::CAMERA_PERSPECTIVE)
CUBE = Rl.load_model_from_mesh(Rl.gen_mesh_cube(2.0, 2.0, 2.0))
rot = 0.0

# distinct cube faces so FX (CRT warp / scanlines / grayscale) are easy to see
face_colors = [Rl::RED, Rl::GREEN, Rl::BLUE, Rl::GOLD, Rl::VIOLET, Rl::ORANGE]

Rl.while_window_open do
  dt = Rl.frame_time
  dt = 1.0 / 60.0 if dt <= 0.0 || dt > 0.1
  rot += 0.6 * dt

  top_ui.process_input # overlay HUD is the interactive context

  # If the UI FXAA is enabled it covers the whole frame (incl the world), so the
  # game FXAA would double-AA the world -> suppress it. (UI-off + game-on = the
  # world-only AA mode, overlay HUD stays crisp.)
  fxaa_game.suppress = fxaa_ui.enabled

  # --------------------------------------- the layered two-stage frame ------
  fx.frame(Rl.time) do |f|
    # ---- GAME LAYER: 3D world + in-world RmlUi, into G_a (catches game FX) ----
    f.game_layer do
      Rl.clear_background(Rl::Color.new(16, 16, 28, 255))
      Rl.mode_3d(cam) do
        Rl.draw_grid(20, 2)
        # a spinning cube — clearly the "game world"; CRT warps it, scanlines line it
        axis = Rl::Vector3.new(0, 1, 0)
        Rl.draw_model_ex(CUBE, Rl::Vector3.new(0, 1, 0), axis, rot * 57.2958,
                         Rl::Vector3.new(1, 1, 1), Rl::WHITE)
        face_colors.each_with_index do |col, i|
          ang = (i * 60 + rot * 90) * 0.0174533
          x = Math.cos(ang) * 5.0
          z = Math.sin(ang) * 5.0
          Rl.draw_cube_v(Rl::Vector3.new(x, 0.5, z), Rl::Vector3.new(0.8, 1.0, 0.8), col)
        end
      end
      game_rot.inner_rml = "rot #{format("%.1f", rot * 57.2958 % 360)}"
      game_ui.update
      game_ui.render # in-world UI -> into G_a (catches game shaders)
    end

    # ---- OVERLAY LAYER: overlay HUD, into C_a (composited after game shaders) ----
    f.overlay_layer do
      ovr_fps.inner_rml = "FPS: #{Rl.get_fps}"
      # sync checkboxes FROM the live enabled state (only touch the attribute on
      # change, to avoid per-frame dirty / re-firing `change`).
      chk_pairs.each do |chk, pass|
        if pass.enabled != chk.has_attribute?("checked")
          pass.enabled ? chk.set_attribute("checked", "") : chk.remove_attribute("checked")
        end
      end
      top_ui.update
      top_ui.render # overlay HUD -> into C_a (crisp through game FX; catches top FX)
    end
  end
end

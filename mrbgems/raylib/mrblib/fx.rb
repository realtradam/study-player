# Jamstack::FX — a layered, two-stage, runtime-toggleable post-processing
# shader pipeline. Pure Ruby over the already-bound raylib shader API; no C.
#
# Two stages over three render layers, so each effect chooses whether it touches
# only the game world (+ in-world UI) or the whole frame (game + overlay HUD):
#
#   GAME LAYER    3D world + in-world RmlUi           -> RenderTexture G
#        |
#   GAME SHADERS  ping-pong chain on G  (gameplay FX; NOT the overlay HUD)
#        |
#   OVERLAY LAYER processed-game quad + overlay RmlUi HUD  -> RenderTexture C
#        |
#   TOP SHADERS   ping-pong chain on C  (complete FX; over EVERYTHING incl HUD)
#        |
#      screen
#
# Flow:  game + game-rmlui -> game shaders -> top-rmlui -> top shaders -> screen
#
# Toggle = skip the pass: Pass#enabled = false removes it from the per-frame
# chain. Zero shader recompilation (shaders load once at construction). An
# optional `intensity` uniform (0..1) lets an effect fade rather than snap.
#
# Usage:
#   fx = Jamstack::FX::Pipeline.new(720, 720)
#   fx.game_shaders << Jamstack::FX::Pass.new("scanlines", Jamstack::FX::SCANLINES)
#   fx.top_shaders  << Jamstack::FX::Pass.new("vignette",  Jamstack::FX::VIGNETTE)
#   Rl.while_window_open do
#     fx.frame(Rl.time) do |f|
#       f.game_layer    { Rl.clear_background(Rl::BLACK); Rl.mode_3d(cam){...}; game_ui.update; game_ui.render }
#       f.overlay_layer { top_ui.update; top_ui.render }
#     end
#   end
#   # runtime toggle (eval bridge / in-game console):
#   #   fx.game_shaders[0].enabled = false   # game FX off -> overlay HUD unaffected
#   #   fx.top_shaders[0].enabled = true     # top FX on  -> whole frame incl HUD
module Jamstack
  module FX
    # ---------------------------------------------------------------- version shim
    # raylib does NOT prepend a #version to user fragment shaders (verified in
    # vendor rlgl.h: rlLoadShader compiles your string as-is). The default vertex
    # shader (used when vs == nil via load_shader_from_memory) outputs the varying
    # `fragTexCoord` and binds the input texture to sampler `texture0` on BOTH
    # targets (GLSL 330 desktop: `in vec2 fragTexCoord`; GLSL 100 web: `varying
    # vec2 fragTexCoord`). So our fragment shader must declare fragTexCoord and
    # sample texture0. The two dialects differ in syntax (varying/in,
    # texture2D/texture, gl_FragColor/out), so a macro shim lets ONE body serve
    # both: the header defines TEXTURE() and FRAG per target.
    #
    # WebGL1-first: the current web build is ES2 (#version 100). Desktop is GL33
    # (#version 330). After a future ES3/WebGL2 upgrade this becomes #version 300
    # es (which shares in/out/texture() syntax with 330), narrowing the gap to
    # just the #version + precision line.
    # Version header (lazy: computed on first use, not at file-load time — fx.rb
    # is globbed before raylib.rb, so the Rl.web? sugar isn't defined yet at load).
    # Uses the underlying Rl._is_web C function (registered at gem init, always
    # available). raylib does NOT prepend #version to user fragment shaders
    # (verified in vendor rlgl.h: rlLoadShader compiles your string as-is). The
    # default vertex shader (vs == nil via load_shader_from_memory) outputs the
    # varying `fragTexCoord` and binds the input texture to sampler `texture0` on
    # BOTH targets (GLSL 330 desktop: `in vec2 fragTexCoord`; GLSL 100 web:
    # `varying vec2 fragTexCoord`). The two dialects differ in syntax, so a macro
    # shim lets ONE body serve both: the header defines TEXTURE()/FRAG per target.
    #
    # WebGL1-first: the current web build is ES2 (#version 100). Desktop is GL33
    # (#version 330). After a future ES3/WebGL2 upgrade this becomes #version 300
    # es (which shares in/out/texture() syntax with 330), narrowing the gap to
    # just the #version + precision line.
    def self.header
      return @header if @header

      @header = if Rl._is_web
                  '#version 300 es
precision highp float;
in vec2 fragTexCoord;
uniform sampler2D texture0;
out vec4 fragColor;
#define FRAG fragColor
#define TEXTURE(s, uv) texture(s, uv)
'
                else
                  '#version 330
in vec2 fragTexCoord;
uniform sampler2D texture0;
out vec4 fragColor;
#define FRAG fragColor
#define TEXTURE(s, uv) texture(s, uv)
'
                end
    end

    # A single post-processing pass: name + fragment-shader body + toggle state.
    # The shader is compiled ONCE at construction (uniform locations cached);
    # toggling `enabled` only changes whether it runs in the per-frame chain.
    class Pass
      attr_accessor :enabled, :intensity, :extra_uniforms, :suppress
      attr_reader :name, :shader

      # name           — human label (introspection / eval-bridge access)
      # body           — GLSL fragment body (NO #version; uses TEXTURE()/FRAG macros)
      # intensity      — 0..1, bound to a `uniform float intensity` if the body has one
      # extra_uniforms — optional {name => value} of extra FLOAT uniforms (cached at
      #                   load, set per frame); used by multi-knob shaders like FXAA
      #                   (subpix / edgeThreshold / edgeThresholdMin). Set values at
      #                   runtime (e.g. from a slider) — no shader recompilation.
      def initialize(name, body, intensity: 1.0, extra_uniforms: {})
        @name = name
        @enabled = true
        @suppress = false
        @intensity = intensity
        @extra_uniforms = extra_uniforms.dup
        src = Jamstack::FX.header + body
        @shader = Rl.load_shader_from_memory(nil, src)
        # Cache uniform locations at load time (never query per frame). raylib
        # returns -1 when the uniform is absent / optimized away; guard before set.
        @loc_intensity  = Rl.get_shader_location(@shader, "intensity")
        @loc_time       = Rl.get_shader_location(@shader, "time")
        @loc_resolution = Rl.get_shader_location(@shader, "resolution")
        # Cache extra-uniform locations once (names fixed at construction).
        @extra_locs = {}
        @extra_uniforms.each_key { |n| @extra_locs[n] = Rl.get_shader_location(@shader, n.to_s) }
      end

      # Render `src_texture` (an Rl::Texture) into `dst_target` (an
      # Rl::RenderTexture) through this pass's shader. Y-flip is mandatory on the
      # source rect (OpenGL bottom-left origin). `scene_texture` is the original
      # pre-chain render (for multi-pass effects that need the unfiltered scene,
      # e.g. a bloom composite); nil when not needed.
      def apply(src_texture, dst_target, t, _scene_texture = nil)
        w = src_texture.width
        h = src_texture.height
        Rl.texture_mode(dst_target) do
          Rl.clear_background(Rl::BLACK)
          Rl.shader_mode(@shader) do
            _set_uniform(@loc_intensity, @intensity, Rl::SHADER_UNIFORM_FLOAT)
            _set_uniform(@loc_time, t, Rl::SHADER_UNIFORM_FLOAT)
            _set_uniform(@loc_resolution, [w, h], Rl::SHADER_UNIFORM_VEC2)
            @extra_uniforms.each { |n, v| _set_uniform(@extra_locs[n], v, Rl::SHADER_UNIFORM_FLOAT) }
            Rl.draw_texture_pro(
              texture: src_texture,
              source: Rl::Rectangle.new(0, 0, w, -h), # negative height = y-flip
              dest: Rl::Rectangle.new(0, 0, w, h),
              tint: Rl::WHITE
            )
          end
        end
      end

      def _set_uniform(loc, value, type)
        return if loc.nil? || loc < 0

        Rl.set_shader_value(@shader, loc, value, type)
      end
    end

    # Owns the four RenderTextures (game + composite ping-pong pairs) and the
    # two shader lists. Render textures are allocated ONCE (FBO creation is
    # expensive + leaks if per-frame); G_a carries a depth attachment by default
    # (load_render_texture makes color+depth) for the 3D world.
    class Pipeline
      attr_reader :game_shaders, :top_shaders, :w, :h, :g, :c

      def initialize(w, h)
        @w = w
        @h = h
        @g = [Rl.load_render_texture(w, h), Rl.load_render_texture(w, h)]  # game ping-pong
        @c = [Rl.load_render_texture(w, h), Rl.load_render_texture(w, h)]  # composite ping-pong
        # BILINEAR on every render texture: FXAA (top stage) REQUIRES sub-pixel
        # bilinear sampling to blend edges; harmless to the other passes. Set once.
        (@g + @c).each { |rt| Rl.set_texture_filter(rt.texture, Rl::TEXTURE_FILTER_BILINEAR) }
        @game_shaders = []
        @top_shaders = []
      end

      # Per-frame entry: yields a Frame the block fills via game_layer/overlay_layer.
      def frame(t)
        yield Frame.new(self, t)
      end

      # Run the enabled passes in `passes` ping-pong over the [a,b] pair, starting
      # from `pair[0]` (already rendered into). Returns the last-written target.
      # No enabled passes => pass-through (pair[0] itself, no extra copy).
      # The pre-chain `pair[0].texture` is handed to each pass as the `scene`
      # (original unfiltered render) for multi-pass effects that need it.
      def apply_chain(passes, pair, t)
        enabled = passes.select { |p| p.enabled && !p.suppress }
        return pair[0] if enabled.empty?

        prev = pair[0]
        cur  = pair[1]
        scene = pair[0].texture
        enabled.each do |p|
          p.apply(prev.texture, cur, t, scene)
          prev, cur = cur, prev
        end
        prev
      end
    end

    # A per-frame builder the Pipeline#frame block receives. game_layer renders
    # the game (+ in-world UI) into G_a and runs the game-shader chain; overlay_layer
    # composites the processed game + overlay HUD into C_a (one FBO so top shaders
    # filter both) and runs the top-shader chain, then blits to screen.
    class Frame
      attr_reader :g_final

      def initialize(pipeline, t)
        @p = pipeline
        @t = t
      end

      # Render the 3D world + in-world RmlUi here (drawn into G_a). After the
      # block, the game-shader chain ping-pongs over G_a<->G_b -> g_final.
      def game_layer
        Rl.texture_mode(@p.g[0]) { yield }
        @g_final = @p.apply_chain(@p.game_shaders, @p.g, @t)
      end

      # Render the overlay HUD here. The processed-game quad is composited into
      # C_a FIRST (y-flipped), then this block draws the overlay HUD on top —
      # both in the SAME texture_mode(C_a) block so top shaders filter both.
      # After the block, the top-shader chain ping-pongs over C_a<->C_b -> c_final,
      # which is blitted to the screen.
      def overlay_layer
        Rl.texture_mode(@p.c[0]) do
          Rl.clear_background(Rl::BLACK)
          Rl.draw_texture_pro(
            texture: @g_final.texture,
            source: Rl::Rectangle.new(0, 0, @p.w, -@p.h), # y-flip
            dest: Rl::Rectangle.new(0, 0, @p.w, @p.h),
            tint: Rl::WHITE
          )
          yield # overlay HUD (top_ui.update; top_ui.render)
        end
        c_final = @p.apply_chain(@p.top_shaders, @p.c, @t)
        Rl.draw(clear_color: Rl::BLACK) do
          Rl.draw_texture_pro(
            texture: c_final.texture,
            source: Rl::Rectangle.new(0, 0, @p.w, -@p.h), # y-flip
            dest: Rl::Rectangle.new(0, 0, @p.w, @p.h),
            tint: Rl::WHITE
          )
        end
      end
    end

    # ------------------------------------------------------------------ shader bodies
    # Each body uses the TEXTURE(s,uv) / FRAG macros (see HEADER) so one source
    # serves #version 100 (web) and #version 330 (desktop). `fragTexCoord` is
    # 0..1 across the fullscreen quad. Declare `uniform float intensity;` to get
    # a runtime-fadeable mix; `uniform float time;` / `uniform vec2 resolution;`
    # are also auto-bound by Pass if present.

    GRAYSCALE = '
uniform float intensity;
void main() {
  vec4 c = TEXTURE(texture0, fragTexCoord);
  float g = dot(c.rgb, vec3(0.299, 0.587, 0.114));
  FRAG = mix(c, vec4(g, g, g, c.a), intensity);
}
'

    INVERT = '
uniform float intensity;
void main() {
  vec4 c = TEXTURE(texture0, fragTexCoord);
  FRAG = mix(c, vec4(1.0 - c.rgb, c.a), intensity);
}
'

    SCANLINES = '
uniform float intensity;
uniform vec2 resolution;
void main() {
  vec4 c = TEXTURE(texture0, fragTexCoord);
  float lines = resolution.y * 0.75;
  float s = 0.6 + 0.4 * step(0.5, fract(fragTexCoord.y * lines));
  FRAG = vec4(c.rgb * mix(1.0, s, intensity), c.a);
}
'

    VIGNETTE = '
uniform float intensity;
void main() {
  vec4 c = TEXTURE(texture0, fragTexCoord);
  float d = distance(fragTexCoord, vec2(0.5, 0.5));
  float v = smoothstep(0.35, 0.75, d);
  FRAG = vec4(c.rgb * (1.0 - v * intensity), c.a);
}
'

    # Warm cinematic color grade (lift shadows toward blue, push highlights warm).
    COLORGRADE = '
uniform float intensity;
void main() {
  vec4 c = TEXTURE(texture0, fragTexCoord);
  vec3 graded = c.rgb;
  graded = mix(graded, graded * vec3(1.06, 1.02, 0.92) + vec3(0.02, 0.01, 0.0), intensity);
  graded = mix(graded, graded + vec3(0.0, 0.0, 0.04) * (1.0 - c.rgb), intensity);
  FRAG = vec4(graded, c.a);
}
'

    # CRT broken into independent, toggleable components (chain them as separate
    # game-stage passes: warp -> aberration -> scanlines). Each is a standalone
    # transform of its input, so any subset can be enabled.

    # Barrel distortion: pull corner texels toward the centre (classic CRT bulge).
    # Out-of-bounds samples go black (the CRT bezel edge).
    WARP = '
uniform float intensity;
void main() {
  vec2 uv = fragTexCoord;
  vec2 cc = uv - vec2(0.5, 0.5);
  float dist = dot(cc, cc);
  uv += cc * dist * 0.22 * intensity;
  if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) {
    FRAG = vec4(0.0, 0.0, 0.0, 1.0);
  } else {
    FRAG = TEXTURE(texture0, uv);
  }
}
'

    # Chromatic aberration ("colour shift"): sample R/G/B at horizontally offset
    # uvs and blend toward the clean sample by intensity (0 = identity).
    ABERRATION = '
uniform float intensity;
void main() {
  vec2 uv = fragTexCoord;
  float ca = 0.006 * intensity;
  float r = TEXTURE(texture0, uv + vec2(ca, 0.0)).r;
  float g = TEXTURE(texture0, uv).g;
  float b = TEXTURE(texture0, uv - vec2(ca, 0.0)).b;
  vec4 c = TEXTURE(texture0, uv);
  FRAG = mix(c, vec4(r, g, b, c.a), intensity);
}
'

    ABERRATION_CMY = '
uniform float intensity;
void main() {
  vec2 uv = fragTexCoord;
  float ca = 0.006 * intensity;
  vec3 cen = TEXTURE(texture0, uv).rgb;
  vec3 sC  = TEXTURE(texture0, uv + vec2(ca, 0.0)).rgb;   // cyan plate    (right)
  vec3 sM  = TEXTURE(texture0, uv + vec2(0.0, ca)).rgb;    // magenta plate (down)
  vec3 sY  = TEXTURE(texture0, uv - vec2(ca, 0.0)).rgb;    // yellow plate  (left)
  // RGB -> CMY (C=1-R, M=1-G, Y=1-B). Subtractive overprint: only the
  // MISREGISTERED ink (centre minus offset plate, clamped >= 0) absorbs its
  // complementary channel -- cyan eats red, magenta eats green, yellow eats
  // blue. Flat regions are untouched; at edges the complements (cyan/magenta/
  // yellow) appear as DARK fringes (vs the additive RGB split BRIGHT red/blue
  // fringes). This is a genuine subtractive colourspace op, not the no-op
  // 1-R then 1-C=R complement round-trip.
  float cy = clamp(cen.r - sC.r, 0.0, 1.0);
  float mg = clamp(cen.g - sM.g, 0.0, 1.0);
  float yl = clamp(cen.b - sY.b, 0.0, 1.0);
  vec3 shifted = vec3(cen.r * (1.0 - cy),
                      cen.g * (1.0 - mg),
                      cen.b * (1.0 - yl));
  FRAG = mix(vec4(cen, 1.0), vec4(shifted, 1.0), intensity);
}
'

    # CRT (all-in-one): barrel distortion + chromatic aberration + scanlines. A
    # clear gameplay effect (would wreck HUD text -> belongs in the GAME stage).
    # Prefer the split WARP / ABERRATION / SCANLINES passes for per-component
    # toggling; this kept as a one-shot convenience.
    CRT = '
uniform float intensity;
uniform vec2 resolution;
uniform float time;
void main() {
  vec2 uv = fragTexCoord;
  vec2 cc = uv - vec2(0.5, 0.5);
  float dist = dot(cc, cc);
  uv += cc * dist * 0.22 * intensity;          // barrel distortion
  vec4 c;
  if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) {
    c = vec4(0.0, 0.0, 0.0, 1.0);
  } else {
    float ca = 0.004 * intensity;             // chromatic aberration
    float r = TEXTURE(texture0, uv + vec2(ca, 0.0)).r;
    float g = TEXTURE(texture0, uv).g;
    float b = TEXTURE(texture0, uv - vec2(ca, 0.0)).b;
    c = vec4(r, g, b, 1.0);
  }
  float scan = 0.88 + 0.12 * sin(fragTexCoord.y * resolution.y * 3.14159);
  FRAG = vec4(c.rgb * mix(1.0, scan, intensity), 1.0);
}
'
    # FXAA 3.11 Quality (NVIDIA / Timothy Lottes), preset 12 (5 edge-search
    # samples — the recommended default: fast + good). Ported to the macro shim.
    # TOP-stage effect (anti-aliases the whole frame incl HUD).
    #
    # Uses GREEN as luma (FXAA_GREEN_AS_LUMA): our RGBA8 render targets have
    # uniform alpha=1, so luma-from-alpha would detect no edges. Caveat: pure
    # red/blue edges (no green) get no AA — see .agents/knowledge/fx-pipeline.md
    # ("GREEN_AS_LUMA + the missing-luma caveat", option B: luma-pack pre-pass).
    #
    # Three RUNTIME float quality knobs (no recompilation): bind via extra_uniforms.
    #   subpix          0.0..1.0     (0.75 default) subpixel AA amount
    #   edgeThreshold   0.063..0.333 (0.166 default) min contrast to count as an edge
    #   edgeThresholdMin 0.0312..0.0833 (0.0833 default) dark-trim
    # REQUIRES bilinear filtering on the input (Pipeline sets BILINEAR on all RTs).
    # rcpFrame is derived from the `resolution` uniform (no extra uniform needed).
    FXAA = '
uniform vec2 resolution;
uniform float subpix;
uniform float edgeThreshold;
uniform float edgeThresholdMin;

float FxaaLuma(vec4 rgba) { return rgba.g; }   // GREEN_AS_LUMA

void main() {
  vec2 pos = fragTexCoord;
  vec2 rcpFrame = vec2(1.0) / resolution;

  vec4 rgbyM = TEXTURE(texture0, pos);
  float lumaM = FxaaLuma(rgbyM);
  float lumaS = FxaaLuma(TEXTURE(texture0, pos + vec2(0.0,  rcpFrame.y)));
  float lumaE = FxaaLuma(TEXTURE(texture0, pos + vec2( rcpFrame.x, 0.0)));
  float lumaN = FxaaLuma(TEXTURE(texture0, pos + vec2(0.0, -rcpFrame.y)));
  float lumaW = FxaaLuma(TEXTURE(texture0, pos + vec2(-rcpFrame.x, 0.0)));

  float maxSM = max(lumaS, lumaM);
  float minSM = min(lumaS, lumaM);
  float maxESM = max(lumaE, maxSM);
  float minESM = min(lumaE, minSM);
  float maxWN = max(lumaN, lumaW);
  float minWN = min(lumaN, lumaW);
  float rangeMax = max(maxWN, maxESM);
  float rangeMin = min(minWN, minESM);
  float rangeMaxScaled = rangeMax * edgeThreshold;
  float range = rangeMax - rangeMin;
  float rangeMaxClamped = max(edgeThresholdMin, rangeMaxScaled);
  if (range < rangeMaxClamped) { FRAG = rgbyM; return; }   // early exit (no edge)

  float lumaNW = FxaaLuma(TEXTURE(texture0, pos + vec2(-rcpFrame.x, -rcpFrame.y)));
  float lumaSE = FxaaLuma(TEXTURE(texture0, pos + vec2( rcpFrame.x,  rcpFrame.y)));
  float lumaNE = FxaaLuma(TEXTURE(texture0, pos + vec2( rcpFrame.x, -rcpFrame.y)));
  float lumaSW = FxaaLuma(TEXTURE(texture0, pos + vec2(-rcpFrame.x,  rcpFrame.y)));

  float lumaNS = lumaN + lumaS;
  float lumaWE = lumaW + lumaE;
  float subpixRcpRange = 1.0 / range;
  float subpixNSWE = lumaNS + lumaWE;
  float edgeHorz1 = (-2.0 * lumaM) + lumaNS;
  float edgeVert1 = (-2.0 * lumaM) + lumaWE;
  float lumaNESE = lumaNE + lumaSE;
  float lumaNWNE = lumaNW + lumaNE;
  float edgeHorz2 = (-2.0 * lumaE) + lumaNESE;
  float edgeVert2 = (-2.0 * lumaN) + lumaNWNE;
  float lumaNWSW = lumaNW + lumaSW;
  float lumaSWSE = lumaSW + lumaSE;
  float edgeHorz4 = (abs(edgeHorz1) * 2.0) + abs(edgeHorz2);
  float edgeVert4 = (abs(edgeVert1) * 2.0) + abs(edgeVert2);
  float edgeHorz3 = (-2.0 * lumaW) + lumaNWSW;
  float edgeVert3 = (-2.0 * lumaS) + lumaSWSE;
  float edgeHorz = abs(edgeHorz3) + edgeHorz4;
  float edgeVert = abs(edgeVert3) + edgeVert4;
  float subpixNWSWNESE = lumaNWSW + lumaNESE;
  float lengthSign = rcpFrame.x;
  bool horzSpan = edgeHorz >= edgeVert;
  float subpixA = subpixNSWE * 2.0 + subpixNWSWNESE;
  if (!horzSpan) lumaN = lumaW;
  if (!horzSpan) lumaS = lumaE;
  if (horzSpan) lengthSign = rcpFrame.y;
  float subpixB = (subpixA * (1.0 / 12.0)) - lumaM;

  float gradientN = lumaN - lumaM;
  float gradientS = lumaS - lumaM;
  float lumaNN = lumaN + lumaM;
  bool pairN = abs(gradientN) >= abs(gradientS);
  float gradient = max(abs(gradientN), abs(gradientS));
  if (pairN) lengthSign = -lengthSign;
  float subpixC = clamp(abs(subpixB) * subpixRcpRange, 0.0, 1.0);

  vec2 posB = pos;
  vec2 offNP;
  offNP.x = (!horzSpan) ? 0.0 : rcpFrame.x;
  offNP.y = ( horzSpan) ? 0.0 : rcpFrame.y;
  if (!horzSpan) posB.x += lengthSign * 0.5;
  if ( horzSpan) posB.y += lengthSign * 0.5;

  // preset 12 edge search: P0=1.0 P1=1.5 P2=2.0 P3=4.0 P4=12.0
  vec2 posN = posB - offNP * 1.0;
  vec2 posP = posB + offNP * 1.0;
  float subpixD = ((-2.0) * subpixC) + 3.0;
  float lumaEndN = FxaaLuma(TEXTURE(texture0, posN));
  float subpixE = subpixC * subpixC;
  float lumaEndP = FxaaLuma(TEXTURE(texture0, posP));

  if (!pairN) lumaNN = lumaS + lumaM;
  float gradientScaled = gradient * 1.0 / 4.0;
  float lumaMM = lumaM - lumaNN * 0.5;
  float subpixF = subpixD * subpixE;
  bool lumaMLTZero = lumaMM < 0.0;

  lumaEndN -= lumaNN * 0.5;
  lumaEndP -= lumaNN * 0.5;
  bool doneN = abs(lumaEndN) >= gradientScaled;
  bool doneP = abs(lumaEndP) >= gradientScaled;
  if (!doneN) posN -= offNP * 1.5;
  bool doneNP = (!doneN) || (!doneP);
  if (!doneP) posP += offNP * 1.5;

  if (doneNP) {
    if (!doneN) lumaEndN = FxaaLuma(TEXTURE(texture0, posN));
    if (!doneP) lumaEndP = FxaaLuma(TEXTURE(texture0, posP));
    if (!doneN) lumaEndN = lumaEndN - lumaNN * 0.5;
    if (!doneP) lumaEndP = lumaEndP - lumaNN * 0.5;
    doneN = abs(lumaEndN) >= gradientScaled;
    doneP = abs(lumaEndP) >= gradientScaled;
    if (!doneN) posN -= offNP * 2.0;
    doneNP = (!doneN) || (!doneP);
    if (!doneP) posP += offNP * 2.0;

    if (doneNP) {
      if (!doneN) lumaEndN = FxaaLuma(TEXTURE(texture0, posN));
      if (!doneP) lumaEndP = FxaaLuma(TEXTURE(texture0, posP));
      if (!doneN) lumaEndN = lumaEndN - lumaNN * 0.5;
      if (!doneP) lumaEndP = lumaEndP - lumaNN * 0.5;
      doneN = abs(lumaEndN) >= gradientScaled;
      doneP = abs(lumaEndP) >= gradientScaled;
      if (!doneN) posN -= offNP * 4.0;
      doneNP = (!doneN) || (!doneP);
      if (!doneP) posP += offNP * 4.0;

      if (doneNP) {
        if (!doneN) lumaEndN = FxaaLuma(TEXTURE(texture0, posN));
        if (!doneP) lumaEndP = FxaaLuma(TEXTURE(texture0, posP));
        if (!doneN) lumaEndN = lumaEndN - lumaNN * 0.5;
        if (!doneP) lumaEndP = lumaEndP - lumaNN * 0.5;
        doneN = abs(lumaEndN) >= gradientScaled;
        doneP = abs(lumaEndP) >= gradientScaled;
        if (!doneN) posN -= offNP * 12.0;
        if (!doneP) posP += offNP * 12.0;
      }
    }
  }

  float dstN = pos.x - posN.x;
  float dstP = posP.x - pos.x;
  if (!horzSpan) dstN = pos.y - posN.y;
  if (!horzSpan) dstP = posP.y - pos.y;

  bool goodSpanN = (lumaEndN < 0.0) != lumaMLTZero;
  float spanLength = (dstP + dstN);
  bool goodSpanP = (lumaEndP < 0.0) != lumaMLTZero;
  float spanLengthRcp = 1.0 / spanLength;

  bool directionN = dstN < dstP;
  float dst = min(dstN, dstP);
  bool goodSpan = directionN ? goodSpanN : goodSpanP;
  float subpixG = subpixF * subpixF;
  float pixelOffset = (dst * (-spanLengthRcp)) + 0.5;
  float subpixH = subpixG * subpix;

  float pixelOffsetGood = goodSpan ? pixelOffset : 0.0;
  float pixelOffsetSubpix = max(pixelOffsetGood, subpixH);
  if (!horzSpan) pos.x += pixelOffsetSubpix * lengthSign;
  if ( horzSpan) pos.y += pixelOffsetSubpix * lengthSign;

  FRAG = vec4(TEXTURE(texture0, pos).rgb, rgbyM.a);
}
'
  end
end

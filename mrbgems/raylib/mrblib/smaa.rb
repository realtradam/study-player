# Jamstack::FX::Smaa — SMAA 1x (Enhanced Subpixel Morphological Antialiasing),
# layered into the two-stage FX pipeline exactly like FXAA. Pure Ruby over the
# bound raylib shader API + one tiny native helper (Rl.update_texture) used to
# upload the generated area/search lookup textures.
#
# SMAA is THREE passes (edge detect -> blend weights -> neighborhood blend) that
# must run consecutively and share two intermediate render textures + two lookup
# textures (areaTex, searchTex). So unlike a single Pass, this is a COMPOSITE
# effect: Jamstack::FX::Smaa ducks as a Pass for Pipeline#apply_chain (responds to
# enabled/suppress/extra_uniforms + apply(src, dst, t, scene)) and runs its own
# 3-pass ping-pong internally, writing the final result into the chain's dst.
#
# Variant: SMAA 1x, PRESET_HIGH with SMAA_DISABLE_DIAG_DETECTION. For SMAA 1x the
# shader passes subsampleIndices = 0, so only offset-row 0 of the areaTex is ever
# sampled; we generate all 7 ortho offset rows anyway (cheap, canonical layout)
# and leave the diagonal (right half of the texture) zeroed, since diagonal
# processing is compiled out. Search texture is full (64x16). Both lookup textures
# are byte-exact with the canonical iryoku/smaa generators (verified).
#
# Multi-texture binding: raylib's DrawTexturePro auto-binds the DRAWN texture to
# unit 0 (texture0). The extra samplers (areaTex/searchTex in pass 2, blendTex in
# pass 3) are bound via Rl.set_shader_value_texture -- raylib's rlSetUniformSampler
# registers the texture id and sets the sampler uniform; the actual GL binding
# happens at the draw flush. So we set_shader_value_texture for each extra sampler
# inside shader_mode, then DrawTexturePro the main texture. areaTex = BILINEAR,
# searchTex = POINT (its own filter); edge/blend intermediate RTs = POINT.
module Jamstack
  module FX
    # The canonical SMAA GLSL (ES3), preprocessed from iryoku/smaa SMAA.hlsl with
    # cpp -DSMAA_GLSL_3 -DSMAA_PRESET_HIGH -DSMAA_DISABLE_DIAG_DETECTION
    # -DSMAA_INCLUDE_VS=0 -DSMAA_INCLUDE_PS=1. All SMAA_* macros expanded
    # (texture(), vec2, mix, mad=a*b+c); diagonal code compiled out. SMAA_RT_METRICS
    # is left as a placeholder -- each pass shader #defines it to a rtMetrics uniform.
    # Reference copy: mrbgems/raylib/tools/smaa_canonical.glsl
    SMAA_LIB = '
vec3 SMAAGatherNeighbours(vec2 texcoord, vec4 offset[3], sampler2D tex) {
    float P = texture(tex, texcoord).r;
    float Pleft = texture(tex, offset[0].xy).r;
    float Ptop = texture(tex, offset[0].zw).r;
    return vec3(P, Pleft, Ptop);
}
void SMAAMovc(bvec2 cond, inout vec2 variable, vec2 value) {
    if (cond.x) variable.x = value.x;
    if (cond.y) variable.y = value.y;
}
void SMAAMovc(bvec4 cond, inout vec4 variable, vec4 value) {
    SMAAMovc(cond.xy, variable.xy, value.xy);
    SMAAMovc(cond.zw, variable.zw, value.zw);
}
vec2 SMAALumaEdgeDetectionPS(vec2 texcoord, vec4 offset[3], sampler2D colorTex) {
    vec2 threshold = vec2(0.1, 0.1);
    vec3 weights = vec3(0.2126, 0.7152, 0.0722);
    float L = dot(texture(colorTex, texcoord).rgb, weights);
    float Lleft = dot(texture(colorTex, offset[0].xy).rgb, weights);
    float Ltop = dot(texture(colorTex, offset[0].zw).rgb, weights);
    vec4 delta;
    delta.xy = abs(L - vec2(Lleft, Ltop));
    vec2 edges = step(threshold, delta.xy);
    if (dot(edges, vec2(1.0, 1.0)) == 0.0) discard;
    float Lright = dot(texture(colorTex, offset[1].xy).rgb, weights);
    float Lbottom = dot(texture(colorTex, offset[1].zw).rgb, weights);
    delta.zw = abs(L - vec2(Lright, Lbottom));
    vec2 maxDelta = max(delta.xy, delta.zw);
    float Lleftleft = dot(texture(colorTex, offset[2].xy).rgb, weights);
    float Ltoptop = dot(texture(colorTex, offset[2].zw).rgb, weights);
    delta.zw = abs(vec2(Lleft, Ltop) - vec2(Lleftleft, Ltoptop));
    maxDelta = max(maxDelta.xy, delta.zw);
    float finalDelta = max(maxDelta.x, maxDelta.y);
    edges.xy *= step(finalDelta, 2.0 * delta.xy);
    return edges;
}
float SMAASearchLength(sampler2D searchTex, vec2 e, float offset) {
    vec2 scale = vec2(66.0, 33.0) * vec2(0.5, -1.0);
    vec2 bias = vec2(66.0, 33.0) * vec2(offset, 1.0);
    scale += vec2(-1.0, 1.0);
    bias += vec2( 0.5, -0.5);
    scale *= 1.0 / vec2(64.0, 16.0);
    bias *= 1.0 / vec2(64.0, 16.0);
    return textureLod(searchTex, (scale * e + bias), 0.0).r;
}
float SMAASearchXLeft(sampler2D edgesTex, sampler2D searchTex, vec2 texcoord, float end) {
    vec2 e = vec2(0.0, 1.0);
    while (texcoord.x > end && e.g > 0.8281 && e.r == 0.0) {
        e = textureLod(edgesTex, texcoord, 0.0).rg;
        texcoord = (-vec2(2.0, 0.0) * SMAA_RT_METRICS.xy + texcoord);
    }
    float offset = (-(255.0 / 127.0) * SMAASearchLength(searchTex, e, 0.0) + 3.25);
    return (SMAA_RT_METRICS.x * offset + texcoord.x);
}
float SMAASearchXRight(sampler2D edgesTex, sampler2D searchTex, vec2 texcoord, float end) {
    vec2 e = vec2(0.0, 1.0);
    while (texcoord.x < end && e.g > 0.8281 && e.r == 0.0) {
        e = textureLod(edgesTex, texcoord, 0.0).rg;
        texcoord = (vec2(2.0, 0.0) * SMAA_RT_METRICS.xy + texcoord);
    }
    float offset = (-(255.0 / 127.0) * SMAASearchLength(searchTex, e, 0.5) + 3.25);
    return (-SMAA_RT_METRICS.x * offset + texcoord.x);
}
float SMAASearchYUp(sampler2D edgesTex, sampler2D searchTex, vec2 texcoord, float end) {
    vec2 e = vec2(1.0, 0.0);
    while (texcoord.y > end && e.r > 0.8281 && e.g == 0.0) {
        e = textureLod(edgesTex, texcoord, 0.0).rg;
        texcoord = (-vec2(0.0, 2.0) * SMAA_RT_METRICS.xy + texcoord);
    }
    float offset = (-(255.0 / 127.0) * SMAASearchLength(searchTex, e.gr, 0.0) + 3.25);
    return (SMAA_RT_METRICS.y * offset + texcoord.y);
}
float SMAASearchYDown(sampler2D edgesTex, sampler2D searchTex, vec2 texcoord, float end) {
    vec2 e = vec2(1.0, 0.0);
    while (texcoord.y < end && e.r > 0.8281 && e.g == 0.0) {
        e = textureLod(edgesTex, texcoord, 0.0).rg;
        texcoord = (vec2(0.0, 2.0) * SMAA_RT_METRICS.xy + texcoord);
    }
    float offset = (-(255.0 / 127.0) * SMAASearchLength(searchTex, e.gr, 0.5) + 3.25);
    return (-SMAA_RT_METRICS.y * offset + texcoord.y);
}
vec2 SMAAArea(sampler2D areaTex, vec2 dist, float e1, float e2, float offset) {
    vec2 texcoord = (vec2(16.0, 16.0) * round(4.0 * vec2(e1, e2)) + dist);
    texcoord = ((1.0 / vec2(160.0, 560.0)) * texcoord + 0.5 * (1.0 / vec2(160.0, 560.0)));
    texcoord.y = ((1.0 / 7.0) * offset + texcoord.y);
    return textureLod(areaTex, texcoord, 0.0).rg;
}
void SMAADetectHorizontalCornerPattern(sampler2D edgesTex, inout vec2 weights, vec4 texcoord, vec2 d) {
    vec2 leftRight = step(d.xy, d.yx);
    vec2 rounding = (1.0 - (25.0 / 100.0)) * leftRight;
    rounding /= leftRight.x + leftRight.y;
    vec2 factor = vec2(1.0, 1.0);
    factor.x -= rounding.x * textureLodOffset(edgesTex, texcoord.xy, 0.0, ivec2(0, 1)).r;
    factor.x -= rounding.y * textureLodOffset(edgesTex, texcoord.zw, 0.0, ivec2(1, 1)).r;
    factor.y -= rounding.x * textureLodOffset(edgesTex, texcoord.xy, 0.0, ivec2(0, -2)).r;
    factor.y -= rounding.y * textureLodOffset(edgesTex, texcoord.zw, 0.0, ivec2(1, -2)).r;
    weights *= clamp(factor, 0.0, 1.0);
}
void SMAADetectVerticalCornerPattern(sampler2D edgesTex, inout vec2 weights, vec4 texcoord, vec2 d) {
    vec2 leftRight = step(d.xy, d.yx);
    vec2 rounding = (1.0 - (25.0 / 100.0)) * leftRight;
    rounding /= leftRight.x + leftRight.y;
    vec2 factor = vec2(1.0, 1.0);
    factor.x -= rounding.x * textureLodOffset(edgesTex, texcoord.xy, 0.0, ivec2( 1, 0)).g;
    factor.x -= rounding.y * textureLodOffset(edgesTex, texcoord.zw, 0.0, ivec2( 1, 1)).g;
    factor.y -= rounding.x * textureLodOffset(edgesTex, texcoord.xy, 0.0, ivec2(-2, 0)).g;
    factor.y -= rounding.y * textureLodOffset(edgesTex, texcoord.zw, 0.0, ivec2(-2, 1)).g;
    weights *= clamp(factor, 0.0, 1.0);
}
vec4 SMAABlendingWeightCalculationPS(vec2 texcoord, vec2 pixcoord, vec4 offset[3],
                                     sampler2D edgesTex, sampler2D areaTex,
                                     sampler2D searchTex, vec4 subsampleIndices) {
    vec4 weights = vec4(0.0, 0.0, 0.0, 0.0);
    vec2 e = texture(edgesTex, texcoord).rg;
    if (e.g > 0.0) {
        vec2 d; vec3 coords;
        coords.x = SMAASearchXLeft(edgesTex, searchTex, offset[0].xy, offset[2].x);
        coords.y = offset[1].y;
        d.x = coords.x;
        float e1 = textureLod(edgesTex, coords.xy, 0.0).r;
        coords.z = SMAASearchXRight(edgesTex, searchTex, offset[0].zw, offset[2].y);
        d.y = coords.z;
        d = abs(round((SMAA_RT_METRICS.zz * d + -pixcoord.xx)));
        vec2 sqrt_d = sqrt(d);
        float e2 = textureLodOffset(edgesTex, coords.zy, 0.0, ivec2(1, 0)).r;
        weights.rg = SMAAArea(areaTex, sqrt_d, e1, e2, subsampleIndices.y);
        coords.y = texcoord.y;
        SMAADetectHorizontalCornerPattern(edgesTex, weights.rg, coords.xyzy, d);
    }
    if (e.r > 0.0) {
        vec2 d; vec3 coords;
        coords.y = SMAASearchYUp(edgesTex, searchTex, offset[1].xy, offset[2].z);
        coords.x = offset[0].x;
        d.x = coords.y;
        float e1 = textureLod(edgesTex, coords.xy, 0.0).g;
        coords.z = SMAASearchYDown(edgesTex, searchTex, offset[1].zw, offset[2].w);
        d.y = coords.z;
        d = abs(round((SMAA_RT_METRICS.ww * d + -pixcoord.yy)));
        vec2 sqrt_d = sqrt(d);
        float e2 = textureLodOffset(edgesTex, coords.xz, 0.0, ivec2(0, 1)).g;
        weights.ba = SMAAArea(areaTex, sqrt_d, e1, e2, subsampleIndices.x);
        coords.x = texcoord.x;
        SMAADetectVerticalCornerPattern(edgesTex, weights.ba, coords.xyxz, d);
    }
    return weights;
}
vec4 SMAANeighborhoodBlendingPS(vec2 texcoord, vec4 offset, sampler2D colorTex, sampler2D blendTex) {
    vec4 a;
    a.x = texture(blendTex, offset.xy).a;
    a.y = texture(blendTex, offset.zw).g;
    a.wz = texture(blendTex, texcoord).xz;
    if (dot(a, vec4(1.0, 1.0, 1.0, 1.0)) < 1e-5) {
        return textureLod(colorTex, texcoord, 0.0);
    }
    bool h = max(a.x, a.z) > max(a.y, a.w);
    vec4 blendingOffset = vec4(0.0, a.y, 0.0, a.w);
    vec2 blendingWeight = a.yw;
    SMAAMovc(bvec4(h, h, h, h), blendingOffset, vec4(a.x, 0.0, a.z, 0.0));
    SMAAMovc(bvec2(h, h), blendingWeight, a.xz);
    blendingWeight /= dot(blendingWeight, vec2(1.0, 1.0));
    vec4 blendingCoord = (blendingOffset * vec4(SMAA_RT_METRICS.xy, -SMAA_RT_METRICS.xy) + texcoord.xyxy);
    vec4 color = blendingWeight.x * textureLod(colorTex, blendingCoord.xy, 0.0);
    color += blendingWeight.y * textureLod(colorTex, blendingCoord.zw, 0.0);
    return color;
}
'

    # The three SMAA passes, built on the FX macro-shim header (TEXTURE/FRAG +
    # texture0 + fragTexCoord). Each #defines SMAA_RT_METRICS to a rtMetrics
    # uniform, inlines the offset[3] math the SMAA vertex shader would have done
    # (raylib's default VS can't), and calls the canonical PS. SMAA_MAX_SEARCH_STEPS
    # = 16 (PRESET_HIGH), used only in the blend pass offset[2].

    # Edge pass uses a runtime `smaaThreshold` uniform (so the slider can tune
    # it without recompiling). Only LumaEdgeDetectionPS uses the threshold, so
    # swap its hardcoded `vec2(0.1,0.1)` for the uniform in the edge pass only.
    SMAA_LIB_EDGE = SMAA_LIB.sub('vec2 threshold = vec2(0.1, 0.1);',
                                  'vec2 threshold = vec2(smaaThreshold);')

    SMAA_EDGE = '
uniform vec4 rtMetrics;
#define SMAA_RT_METRICS rtMetrics
uniform float smaaThreshold;
' + SMAA_LIB_EDGE + '
void main() {
  vec4 offset[3];
  offset[0] = rtMetrics.xyxy * vec4(-1.0, 0.0, 0.0, -1.0) + fragTexCoord.xyxy;
  offset[1] = rtMetrics.xyxy * vec4( 1.0, 0.0, 0.0,  1.0) + fragTexCoord.xyxy;
  offset[2] = rtMetrics.xyxy * vec4(-2.0, 0.0, 0.0, -2.0) + fragTexCoord.xyxy;
  vec2 edges = SMAALumaEdgeDetectionPS(fragTexCoord, offset, texture0);
  FRAG = vec4(edges, 0.0, 0.0);
}
'

    SMAA_BLEND = '
uniform vec4 rtMetrics;
#define SMAA_RT_METRICS rtMetrics
uniform sampler2D areaTex;
uniform sampler2D searchTex;
' + SMAA_LIB + '
void main() {
  vec2 pixcoord = fragTexCoord * rtMetrics.zw;
  vec4 offset[3];
  offset[0] = rtMetrics.xyxy * vec4(-0.25, -0.125,  1.25, -0.125) + fragTexCoord.xyxy;
  offset[1] = rtMetrics.xyxy * vec4(-0.125, -0.25, -0.125,  1.25) + fragTexCoord.xyxy;
  offset[2] = rtMetrics.xxyy * vec4(-2.0, 2.0, -2.0, 2.0) * 16.0 + vec4(offset[0].xz, offset[1].yw);
  vec4 weights = SMAABlendingWeightCalculationPS(fragTexCoord, pixcoord, offset,
                                                  texture0, areaTex, searchTex, vec4(0.0));
  FRAG = weights;
}
'

    SMAA_NEIGHBOR = '
uniform vec4 rtMetrics;
#define SMAA_RT_METRICS rtMetrics
uniform sampler2D blendTex;
' + SMAA_LIB + '
void main() {
  vec4 offset = rtMetrics.xyxy * vec4(1.0, 0.0, 0.0, 1.0) + fragTexCoord.xyxy;
  vec4 color = SMAANeighborhoodBlendingPS(fragTexCoord, offset, texture0, blendTex);
  FRAG = color;
}
'

    # ---- lookup textures ----
    # The areaTex (160x560 RGBA8) and searchTex (64x16 RGBA8) live as baked
    # canonical bytes in C (src/smaa_tex_data.c, AUTO-GENERATED by
    # tools/gen_smaa_tex.rb from iryoku/smaa Scripts/*.py -- ortho region + search
    # R channel byte-exact). Exposed to Ruby as Strings via Rl.smaa_area_bytes /
    # Rl.smaa_search_bytes (mrb_str_new at runtime) and uploaded with
    # Rl.update_texture. Runtime generation in mruby is too slow (~12s) and a
    # ~358KB Ruby string literal hangs the irep loader, so the data lives in C.
    # Area is ortho-only (diag half zeroed) since SMAA runs with
    # SMAA_DISABLE_DIAG_DETECTION.
    SMAA_BUILD_TAG = "flipv2-1757-pass2minusH"
    AREATEX_W = 160
    AREATEX_H = 560
    SEARCHTEX_W = 64
    SEARCHTEX_H = 16

    # ------------------------------------------------------------------ Smaa pass
    # A composite SMAA 1x effect: ducks as a Pass for Pipeline#apply_chain
    # (enabled/suppress/extra_uniforms + apply), runs 3 internal passes.
    class Smaa
      attr_accessor :enabled, :suppress, :extra_uniforms
      attr_reader :name

      # name      — human label
      # w, h      — render size (must match the Pipeline's RT size)
      # threshold — SMAA edge-detection threshold (0.1 default). Slider knob.
      def initialize(name, w, h, threshold: 0.1)
        @name = name
        @enabled = true
        @suppress = false
        @w = w
        @h = h
        @extra_uniforms = { threshold: threshold }

        hdr = Jamstack::FX.header
        @edge_sh    = Rl.load_shader_from_memory(nil, hdr + SMAA_EDGE)
        @blend_sh   = Rl.load_shader_from_memory(nil, hdr + SMAA_BLEND)
        @neighbor_sh = Rl.load_shader_from_memory(nil, hdr + SMAA_NEIGHBOR)

        # uniform locations (cached once):
        [@edge_sh, @blend_sh, @neighbor_sh].each { |s| s.freeze }
        @loc_rt_edge     = Rl.get_shader_location(@edge_sh, "rtMetrics")
        @loc_thresh      = Rl.get_shader_location(@edge_sh, "smaaThreshold")
        @loc_rt_blend    = Rl.get_shader_location(@blend_sh, "rtMetrics")
        @loc_rt_neighbor = Rl.get_shader_location(@neighbor_sh, "rtMetrics")
        @loc_area   = Rl.get_shader_location(@blend_sh, "areaTex")
        @loc_search = Rl.get_shader_location(@blend_sh, "searchTex")
        @loc_blend  = Rl.get_shader_location(@neighbor_sh, "blendTex")

        # intermediate render textures. BOTH MUST BE BILINEAR, not POINT: SMAA's
        # areaTex lookup (SMAAArea) reads the crossing edges e1/e2 via
        # textureLod(edgesTex, <sub-texel search coords>) — with POINT filtering
        # e1/e2 are binary {0,1} -> round(4*e) in {0,4} -> SMAAArea samples the
        # areaTex's ZERO corner regions -> ZERO blend weights -> NO AA. With
        # BILINEAR, the sub-texel sample blends 4 edge texels -> e1/e2 in
        # {0,0.25,0.75,1.0} -> round(4*e) in {0,1,3,4} -> reads the real area data
        # (the areaTex is the iryoku gather layout, data at {1,3}^2). blend_rt
        # likewise must be BILINEAR for pass 3's neighbourhood blend to interpolate.
        # (Matches three.js: edgesRT/weightsRT are LINEAR+HalfFloat.) The earlier
        # POINT setting was the root cause of "SMAA enabled but no anti-aliasing."
        @edge_rt   = Rl.load_render_texture(w, h)
        @blend_rt  = Rl.load_render_texture(w, h)
        [@edge_rt, @blend_rt].each { |rt| Rl.set_texture_filter(rt.texture, Rl::TEXTURE_FILTER_BILINEAR) }

        # lookup textures: pull the baked C bytes (smaa_tex_data.c, generated by
        # tools/gen_smaa_tex.rb) + upload via the native update_texture.
        # areaTex = BILINEAR (the shader bilinearly interpolates the area LUT);
        # searchTex = POINT (it's an index — must not interpolate).
        area_img  = Rl.gen_image_color(AREATEX_W, AREATEX_H, Rl::BLANK)
        @area_tex = Rl.load_texture_from_image(area_img)
        Rl.update_texture(@area_tex, Rl.smaa_area_bytes)
        Rl.set_texture_filter(@area_tex, Rl::TEXTURE_FILTER_BILINEAR)
        Rl.unload_image(area_img)

        search_img  = Rl.gen_image_color(SEARCHTEX_W, SEARCHTEX_H, Rl::BLANK)
        @search_tex = Rl.load_texture_from_image(search_img)
        Rl.update_texture(@search_tex, Rl.smaa_search_bytes)
        Rl.set_texture_filter(@search_tex, Rl::TEXTURE_FILTER_POINT)
        Rl.unload_image(search_img)
      end

      # Composite 3-pass SMAA. Reads `src_texture` (the chain input), writes the
      # AA'd result into `dst_target`. _scene unused (SMAA pass 3 re-reads src,
      # not the pre-chain scene).
      def apply(src_texture, dst_target, _t, _scene_texture = nil)
        w = src_texture.width
        h = src_texture.height
        rt = [1.0 / w, 1.0 / h, w.to_f, h.to_f]

        # pass 1 — luma edge detection: draw src -> edge_rt (texture0 = src).
        Rl.texture_mode(@edge_rt) do
          # BLEND_NONE isn't in this raylib version and rlSetBlendFactors isn't
          # bound, so write data directly via BLEND_ALPHA_PREMULTIPLY + a BLANK
          # clear: glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA) -> out = src +
          # dst*(1-src.a); with dst=0 (BLANK) that's a direct write (correct
          # alpha, no corruption). The old default BLEND_ALPHA + BLACK clear
          # (alpha=1) left alpha=1 on the zero-alpha non-edge output, which
          # pass 3 reads as the right blend weight a.x -> uniform left shift.
          Rl.clear_background(Rl::BLANK)
          Rl.blend_mode(Rl::BLEND_ALPHA_PREMULTIPLY) do
            Rl.shader_mode(@edge_sh) do
              _u(@edge_sh, @loc_rt_edge, rt)
              _u(@edge_sh, @loc_thresh, @extra_uniforms[:threshold] || 0.1, Rl::SHADER_UNIFORM_FLOAT)
              Rl.draw_texture_pro(
                texture: src_texture, source: Rl::Rectangle.new(0, 0, w, -h),
                dest: Rl::Rectangle.new(0, 0, w, h), origin: Rl::Vector2.new(0, 0),
                rotation: 0.0, tint: Rl::WHITE
              )
            end
          end
        end

        # pass 2 — blending weights: draw edge_rt -> blend_rt; bind area+search.
        # edge_rt is drawn WITH the y-flip (source height -h), the SAME as passes
        # 1 & 3, so all three passes share ONE orientation (blend_rt then matches
        # src_texture's flipped parity, so pass 3's bound-sampler read of blend_rt
        # at the (flipped) fragTexCoord aligns with the drawn color). The prior +h
        # (commit 3f39485) broke this -> vertically-mirrored weights -> corrupted
        # output. Verified: -h => clean AA; +h => corrupted shapes.
        Rl.texture_mode(@blend_rt) do
          # Same direct-write as pass 1 (PREMULTIPLY + BLANK): without it the
          # BLACK clear's alpha=1 is preserved on zero-alpha non-edge output,
          # so pass 3 reads a.x=1 everywhere and shifts the image 1px left.
          Rl.clear_background(Rl::BLANK)
          Rl.blend_mode(Rl::BLEND_ALPHA_PREMULTIPLY) do
            Rl.shader_mode(@blend_sh) do
              _u(@blend_sh, @loc_rt_blend, rt)
              Rl.set_shader_value_texture(@blend_sh, @loc_area, @area_tex)
              Rl.set_shader_value_texture(@blend_sh, @loc_search, @search_tex)
              Rl.draw_texture_pro(
                texture: @edge_rt.texture, source: Rl::Rectangle.new(0, 0, w, -h),
                dest: Rl::Rectangle.new(0, 0, w, h), origin: Rl::Vector2.new(0, 0),
                rotation: 0.0, tint: Rl::WHITE
              )
            end
          end
        end

        # pass 3 — neighborhood blending: draw src -> dst; bind blend_rt.
        Rl.texture_mode(dst_target) do
          Rl.clear_background(Rl::BLACK)
          Rl.shader_mode(@neighbor_sh) do
            _u(@neighbor_sh, @loc_rt_neighbor, rt)
            Rl.set_shader_value_texture(@neighbor_sh, @loc_blend, @blend_rt.texture)
            Rl.draw_texture_pro(
              texture: src_texture, source: Rl::Rectangle.new(0, 0, w, -h),
              dest: Rl::Rectangle.new(0, 0, w, h), origin: Rl::Vector2.new(0, 0),
              rotation: 0.0, tint: Rl::WHITE
            )
          end
        end
      end

      def _u(shader, loc, value, type = Rl::SHADER_UNIFORM_VEC4)
        return if loc.nil? || loc < 0
        Rl.set_shader_value(shader, loc, value, type)
      end
    end
  end
end

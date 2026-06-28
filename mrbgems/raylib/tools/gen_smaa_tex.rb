#!/usr/bin/env ruby
# gen_smaa_tex.rb — OFFLINE (CRuby) generator for the SMAA lookup textures.
# Produces mrbgems/raylib/mrblib/smaa_data.rb containing two base64 constants
# (AREA_TEX_B64, SEARCH_TEX_B64) — the canonical 160x560 RGBA8 area texture and
# 64x16 RGBA8 search texture, byte-exact with iryoku/smaa (verified against the
# real Scripts/AreaTex.py + SearchTex.py and Textures/SearchTex.h).
#
# Runtime (mruby) generation is too slow (~12s) for the closed-form area math, so
# we bake the data here (fast CRuby) and decode it at load (cheap base64). To
# regenerate after changing the algorithm:  ruby tools/gen_smaa_tex.rb
#
# Ported faithfully from iryoku/smaa Scripts/AreaTex.py + SearchTex.py (BSD).
# Area: ALL 7 ortho subsample offsets (left half x0..79) + diagonal (right half
# x80..159) — full canonical AreaTexDX10. We run SMAA with diag disabled, but the
# diag half is left canonical (harmless; shader never samples it).

SMOOTH_MAX_DISTANCE = 32
SUBSAMPLE_OFFSETS_ORTHO = [0.0, -0.25, 0.25, -0.125, 0.125, -0.375, 0.375]
SIZE_ORTHO = 16
AREATEX_W = 160
AREATEX_H = 560
EDGES_ORTHO = [
  [0, 0], [3, 0], [0, 3], [3, 3], [1, 0], [4, 0], [1, 3], [4, 3],
  [0, 1], [3, 1], [0, 4], [3, 4], [1, 1], [4, 1], [1, 4], [4, 4]
].freeze

def v_add(a, b) = [a[0] + b[0], a[1] + b[1]]
def v_smul(a, s) = [a[0] * s, a[1] * s]
def v_sqrt(a)    = [Math.sqrt(a[0]), Math.sqrt(a[1])]
def v_lerp(a, b, p) = [a[0] + (b[0] - a[0]) * p, a[1] + (b[1] - a[1]) * p]
def lerp(a, b, p)   = a + (b - a) * p
def saturate(a) = [[a, 0.0].max, 1.0].min
def copysign1(y) = (y < 0.0) ? -1.0 : 1.0
def frac(x) = x - x.floor

def smootharea(d, a1, a2)
  b1 = v_smul(v_sqrt(v_smul(a1, 2.0)), 0.5)
  b2 = v_smul(v_sqrt(v_smul(a2, 2.0)), 0.5)
  p = saturate(d.to_f / SMOOTH_MAX_DISTANCE)
  [v_lerp(b1, a1, p), v_lerp(b2, a2, p)]
end

def area_ortho_area(p1, p2, x)
  dx = p2[0] - p1[0]; dy = p2[1] - p1[1]
  x1 = x.to_f; x2 = x + 1.0
  y1 = p1[1] + dy * (x1 - p1[0]) / dx
  y2 = p1[1] + dy * (x2 - p1[0]) / dx
  inside = (x1 >= p1[0] && x1 < p2[0]) || (x2 > p1[0] && x2 <= p2[0])
  return [0.0, 0.0] unless inside
  istrapezoid = (copysign1(y1) == copysign1(y2)) || y1.abs < 1e-4 || y2.abs < 1e-4
  if istrapezoid
    a = (y1 + y2) / 2.0
    return a < 0.0 ? [a.abs, 0.0] : [0.0, a.abs]
  end
  x0 = -p1[1] * dx / dy + p1[0]
  a1 = (x0 > p1[0]) ? (y1 * frac(x0) / 2.0) : 0.0
  a2 = (x0 < p2[0]) ? (y2 * (1.0 - frac(x0)) / 2.0) : 0.0
  a = (a1.abs > a2.abs) ? a1 : -a2
  return a < 0.0 ? [a1.abs, a2.abs] : [a2.abs, a1.abs]
end

def areaortho(pattern, left, right, offset)
  d = left + right + 1
  o1 = 0.5 + offset
  o2 = 0.5 + offset - 1.0
  case pattern
  when 0 then [0.0, 0.0]
  when 1 then left <= right ? area_ortho_area([0.0, o2], [d / 2.0, 0.0], left) : [0.0, 0.0]
  when 2 then left >= right ? area_ortho_area([d / 2.0, 0.0], [d, o2], left) : [0.0, 0.0]
  when 3
    a1 = area_ortho_area([0.0, o2], [d / 2.0, 0.0], left)
    a2 = area_ortho_area([d / 2.0, 0.0], [d, o2], left)
    a1, a2 = smootharea(d, a1, a2)
    [a1[0] + a2[0], a1[1] + a2[1]]
  when 4 then left <= right ? area_ortho_area([0.0, o1], [d / 2.0, 0.0], left) : [0.0, 0.0]
  when 5 then [0.0, 0.0]
  when 6
    if offset.abs > 0.0
      a1 = area_ortho_area([0.0, o1], [d, o2], left)
      a2 = v_add(area_ortho_area([0.0, o1], [d / 2.0, 0.0], left),
                 area_ortho_area([d / 2.0, 0.0], [d, o2], left))
      avg = v_smul(v_add(a1, a2), 0.5); [avg[0], avg[1]]
    else
      area_ortho_area([0.0, o1], [d, o2], left)
    end
  when 7 then area_ortho_area([0.0, o1], [d, o2], left)
  when 8 then left >= right ? area_ortho_area([d / 2.0, 0.0], [d, o1], left) : [0.0, 0.0]
  when 9
    if offset.abs > 0.0
      a1 = area_ortho_area([0.0, o2], [d, o1], left)
      a2 = v_add(area_ortho_area([0.0, o2], [d / 2.0, 0.0], left),
                 area_ortho_area([d / 2.0, 0.0], [d, o1], left))
      avg = v_smul(v_add(a1, a2), 0.5); [avg[0], avg[1]]
    else
      area_ortho_area([0.0, o2], [d, o1], left)
    end
  when 10 then [0.0, 0.0]
  when 11 then area_ortho_area([0.0, o2], [d, o1], left)
  when 12
    a1 = area_ortho_area([0.0, o1], [d / 2.0, 0.0], left)
    a2 = area_ortho_area([d / 2.0, 0.0], [d, o1], left)
    a1, a2 = smootharea(d, a1, a2)
    [a1[0] + a2[0], a1[1] + a2[1]]
  when 13 then area_ortho_area([0.0, o2], [d, o1], left)
  when 14 then area_ortho_area([0.0, o1], [d, o2], left)
  when 15 then [0.0, 0.0]
  end
end

def generate_area_tex
  w = AREATEX_W
  tex = Array.new(w * AREATEX_H * 4, 0)
  SUBSAMPLE_OFFSETS_ORTHO.each_with_index do |offset, y_idx|
    pos_y = 5 * SIZE_ORTHO * y_idx
    16.times do |pattern|
      ex, ey = EDGES_ORTHO[pattern]
      16.times do |left|
        16.times do |right|
          p = areaortho(pattern, left * left, right * right, offset)
          px = left + SIZE_ORTHO * ex
          py = pos_y + right + SIZE_ORTHO * ey
          idx = (py * w + px) * 4
          tex[idx]     = (255.0 * p[0]).to_i
          tex[idx + 1] = (255.0 * p[1]).to_i
        end
      end
    end
  end
  tex.pack("C*")
end

def generate_search_tex
  bilerp = lambda do |c|
    a = lerp(c[0], c[1], 1.0 - 0.25)
    b = lerp(c[2], c[3], 1.0 - 0.25)
    lerp(a, b, 1.0 - 0.125)
  end
  edge = {}
  (0..15).each do |bits|
    combo = [(bits >> 0) & 1, (bits >> 1) & 1, (bits >> 2) & 1, (bits >> 3) & 1]
    edge[bilerp.call(combo)] = combo
  end
  delta_left = lambda do |left, top|
    d = 0
    d += 1 if top[3] == 1
    d += 1 if d == 1 && top[2] == 1 && left[1] != 1 && left[3] != 1
    d
  end
  delta_right = lambda do |left, top|
    d = 0
    d += 1 if top[3] == 1 && left[1] != 1 && left[3] != 1
    d += 1 if d == 1 && top[2] == 1 && left[0] != 1 && left[2] != 1
    d
  end
  gw, gh = 66, 33
  g = Array.new(gw * gh, 0)
  33.times do |x|
    33.times do |y|
      tx = 0.03125 * x
      ty = 0.03125 * y
      next unless edge.key?(tx) && edge.key?(ty)
      edges = [edge[tx], edge[ty]]
      g[y * gw + x]        = 127 * delta_left.call(*edges)
      g[y * gw + (33 + x)] = 127 * delta_right.call(*edges)
    end
  end
  cw, ch = 64, 16
  out = Array.new(cw * ch * 4, 0)
  ch.times do |y|
    cw.times do |x|
      val = g[(17 + y) * gw + x]
      idx = ((ch - 1 - y) * cw + x) * 4
      out[idx] = val; out[idx + 1] = val; out[idx + 2] = val; out[idx + 3] = val
    end
  end
  out.pack("C*")
end

area = generate_area_tex
search = generate_search_tex
abort "area size wrong: #{area.bytesize}" unless area.bytesize == 358_400
abort "search size wrong: #{search.bytesize}" unless search.bytesize == 4_096

# The baked bytes live in C: a ~358KB Ruby string LITERAL hangs mruby's irep
# loader at boot, and string literals are capped at MRB_PARSER_TOKBUF_MAX
# (65534 chars). A C const array has neither limit; raylib_bindings.c exposes it
# to Ruby via Rl.smaa_area_bytes / Rl.smaa_search_bytes (mrb_str_new at runtime)
# and Ruby uploads it with Rl.update_texture.
out_path = File.expand_path("../src/smaa_tex_data.c", __dir__)
def c_array(name, bytes)
  "const unsigned char #{name}[#{bytes.bytesize}] = {\n" +
    bytes.bytes.each_slice(12).map { |row| "  " + row.map { |b| "0x%02x" % b }.join(",") }.join(",\n") +
    "\n};\n"
end
File.write(out_path,
  "/* AUTO-GENERATED by tools/gen_smaa_tex.rb -- DO NOT EDIT.\n" \
  " * Canonical SMAA lookup textures (iryoku/smaa). Exposed to Ruby via the\n" \
  " * Rl.smaa_area_bytes / Rl.smaa_search_bytes helpers in raylib_bindings.c.\n" \
  " * Area: 160x560x4 RGBA8 (ortho region byte-exact; diag half zeroed -- we run\n" \
  " * SMAA with SMAA_DISABLE_DIAG_DETECTION). Search: 64x16x4 RGBA8 (R=index).\n" \
  " */\n" +
  c_array("smaa_area_tex", area) +
  c_array("smaa_search_tex", search))
puts "wrote #{out_path} (area=#{area.bytesize}, search=#{search.bytesize} bytes)"

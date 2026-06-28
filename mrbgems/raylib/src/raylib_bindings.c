/* raylib mrbgem entry point.
 *
 * The bulk of the bindings (all supported structs/enums/functions) are generated
 * into raylib_gen.c by tools/gen_raylib.rb from raylib's official raylib_api.json.
 * This file only holds the hand-written pieces the generator can't express:
 *   - platform detection (Rl._is_web)
 *   - the web main-loop seam (Rl._run_web_loop)
 *   - Rl.update_texture (UpdateTexture has a `const void *pixels` arg the
 *     generator skips; takes a Texture + a binary String of raw bytes)
 * and calls the generated registrar.
 */
#include <mruby.h>
#include <mruby/data.h>    /* DATA_PTR (unchecked struct accessor) */
#include <mruby/string.h>  /* RSTRING_PTR */
#include <raylib.h>
#ifdef __EMSCRIPTEN__
#include <emscripten/emscripten.h>
#endif

/* defined in the generated raylib_gen.c */
void rl_define_generated(mrb_state *mrb);

/*
 * SMAA lookup textures (baked canonical bytes from iryoku/smaa, generated into
 * smaa_tex_data.c by tools/gen_smaa_tex.rb). Exposed to Ruby as Strings so the
 * Jamstack::FX::Smaa composite (mrblib/smaa.rb) can upload them via
 * Rl.update_texture. Lives in C (not a Ruby literal) because a ~358KB string
 * literal both exceeds mruby's 65534-char literal cap AND hangs the irep loader
 * at boot; mrb_str_new at runtime has neither limit.
 */
extern const unsigned char smaa_area_tex[];
extern const unsigned char smaa_search_tex[];
static const size_t smaa_area_tex_len = 358400;
static const size_t smaa_search_tex_len = 4096;

static mrb_value
rl_smaa_area_bytes(mrb_state *mrb, mrb_value self)
{
  return mrb_str_new(mrb, (const char *)smaa_area_tex, smaa_area_tex_len);
}

static mrb_value
rl_smaa_search_bytes(mrb_state *mrb, mrb_value self)
{
  return mrb_str_new(mrb, (const char *)smaa_search_tex, smaa_search_tex_len);
}

/*
 * Rl.update_texture(texture, bytes) -> nil
 *
 * Wraps raylib's UpdateTexture: uploads raw pixel bytes into an existing GPU
 * Texture2D. The generator skips UpdateTexture (and LoadImageFromMemory) because
 * their `const void *` args aren't auto-marshalable; this helper unpacks a Ruby
 * String of raw bytes. Used by Jamstack::FX::Smaa to upload the generated
 * area/search lookup textures (RGBA8). The texture's .format must match the byte
 * layout (gen_image_color + load_texture_from_image yields RGBA8). Bytes may
 * contain NULs — UpdateTexture reads width*height*bpp, not a C string.
 *
 * Texture2D is accessed via DATA_PTR (unchecked) rather than the static
 * rl_ptr_Texture accessor in raylib_gen.c; the call site always passes a Texture.
 */
static mrb_value
rl_update_texture(mrb_state *mrb, mrb_value self)
{
  mrb_value tex_val, bytes_val;
  mrb_get_args(mrb, "oS", &tex_val, &bytes_val);
  UpdateTexture(*((Texture2D *)DATA_PTR(tex_val)), RSTRING_PTR(bytes_val));
  return mrb_nil_value();
}

static mrb_value
rl_is_web(mrb_state *mrb, mrb_value self)
{
#ifdef __EMSCRIPTEN__
  return mrb_true_value();
#else
  return mrb_false_value();
#endif
}

#ifdef __EMSCRIPTEN__
static mrb_state *g_loop_mrb = NULL;
static mrb_value g_loop_block;

static void
web_frame(void)
{
  mrb_yield(g_loop_mrb, g_loop_block, mrb_nil_value());
}

static mrb_value
rl_run_web_loop(mrb_state *mrb, mrb_value self)
{
  mrb_value blk;
  mrb_get_args(mrb, "&", &blk);
  g_loop_mrb = mrb;
  g_loop_block = blk;
  mrb_gc_register(mrb, blk);
  emscripten_set_main_loop(web_frame, 0, 1); /* unwinds; never returns */
  return mrb_nil_value();
}
#else
static mrb_value
rl_run_web_loop(mrb_state *mrb, mrb_value self)
{
  return mrb_nil_value();
}
#endif

void
mrb_raylib_gem_init(mrb_state *mrb)
{
  rl_define_generated(mrb);

  struct RClass *rl = mrb_define_module(mrb, "Rl");
  mrb_define_module_function(mrb, rl, "_is_web", rl_is_web, MRB_ARGS_NONE());
  mrb_define_module_function(mrb, rl, "_run_web_loop", rl_run_web_loop, MRB_ARGS_BLOCK());
  mrb_define_module_function(mrb, rl, "update_texture", rl_update_texture, MRB_ARGS_REQ(2));
  mrb_define_module_function(mrb, rl, "smaa_area_bytes", rl_smaa_area_bytes, MRB_ARGS_NONE());
  mrb_define_module_function(mrb, rl, "smaa_search_bytes", rl_smaa_search_bytes, MRB_ARGS_NONE());
}

void
mrb_raylib_gem_final(mrb_state *mrb)
{
}

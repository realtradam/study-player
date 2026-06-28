/* Host entry point: boots mruby, loads and runs the game's main.rb.
 *
 * Minimal spine. A release build would embed compiled bytecode instead of
 * reading source at runtime (see BUILD_SYSTEM.md 4), but for the proof we load
 * the Ruby file directly.
 */
#define _POSIX_C_SOURCE 200809L   /* fileno/dup/dup2 under -std=c11 (stdout capture) */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>          /* memcpy (web eval result copy) */
#include <unistd.h>          /* dup, dup2, close (stdout capture) */
#include <mruby.h>
#include <mruby/compile.h>
#include <mruby/string.h>
#include <mruby/array.h>     /* mrb_ary_new / mrb_ary_push (ARGV) */
#include <mruby/variable.h>  /* mrb_const_get (web eval entry) */
#ifdef __EMSCRIPTEN__
#include <emscripten.h>
#endif

static char *
read_file(const char *path, size_t *out_len)
{
  FILE *f = fopen(path, "rb");
  if (!f) { fprintf(stderr, "could not open %s\n", path); return NULL; }
  fseek(f, 0, SEEK_END);
  long len = ftell(f);
  fseek(f, 0, SEEK_SET);
  char *buf = (char *)malloc(len + 1);
  if (!buf) { fclose(f); return NULL; }
  size_t n = fread(buf, 1, len, f);
  buf[n] = '\0';
  fclose(f);
  if (out_len) *out_len = n;
  return buf;
}

/* --- Jamstack agent bridge (R1): native bits ------------------------------- *
 * The bridge runs Ruby in the LIVE game on the main thread; the bulk lives in
 * Ruby (mrbgems/raylib/mrblib/bridge.rb). Two things must be done in C:
 *
 *  1. stdout capture. mruby's puts/print/p write straight to C fd 1 (NOT via
 *     $stdout, and there is no __printstr__/StringIO in this build), so the only
 *     way to capture an eval's output is to redirect fd 1 around the eval.
 *     Jamstack.__cap_begin / __cap_end bracket Jamstack::Bridge.eval_code.
 *  2. env access. There is no ENV in this gembox, so the JAMSTACK_BRIDGE gate is
 *     read via Jamstack.getenv (C getenv).
 *
 * Dev-only by construction; see .agents/knowledge/agent-bridge.md.            */
static mrb_state *g_mrb = NULL;   /* live interpreter (web jamstack_eval, R4) */
static int   g_saved_fd1 = -1;
static FILE *g_cap_tmp   = NULL;

static mrb_value
js_cap_begin(mrb_state *mrb, mrb_value self)
{
  (void)self;
  if (g_saved_fd1 != -1) return mrb_false_value();   /* already capturing */
  fflush(stdout);
  g_cap_tmp = tmpfile();
  if (!g_cap_tmp) return mrb_false_value();
  g_saved_fd1 = dup(1);
  dup2(fileno(g_cap_tmp), 1);
  return mrb_true_value();
}

static mrb_value
js_cap_end(mrb_state *mrb, mrb_value self)
{
  (void)self;
  if (g_saved_fd1 == -1) return mrb_str_new(mrb, "", 0);
  fflush(stdout);
  dup2(g_saved_fd1, 1);
  close(g_saved_fd1);
  g_saved_fd1 = -1;

  fflush(g_cap_tmp);
  fseek(g_cap_tmp, 0, SEEK_END);
  long n = ftell(g_cap_tmp);
  fseek(g_cap_tmp, 0, SEEK_SET);
  mrb_value s;
  if (n > 0) {
    char *buf = (char *)malloc((size_t)n);
    size_t r = buf ? fread(buf, 1, (size_t)n, g_cap_tmp) : 0;
    s = mrb_str_new(mrb, buf, (mrb_int)r);
    free(buf);
  } else {
    s = mrb_str_new(mrb, "", 0);
  }
  fclose(g_cap_tmp);
  g_cap_tmp = NULL;
  return s;
}

static mrb_value
js_getenv(mrb_state *mrb, mrb_value self)
{
  (void)self;
  const char *name;
  mrb_get_args(mrb, "z", &name);
  const char *v = getenv(name);
  if (!v) return mrb_nil_value();
  return mrb_str_new_cstr(mrb, v);
}

/* Run arbitrary JS on web (no-op on desktop). Used for canvas/rendering controls. */
#ifdef __EMSCRIPTEN__
static mrb_value
jamstack_eval_js(mrb_state *mrb, mrb_value self)
{
  const char *code;
  mrb_get_args(mrb, "z", &code);
  emscripten_run_script(code);
  return mrb_nil_value();
}
#else
static mrb_value
jamstack_eval_js(mrb_state *mrb, mrb_value self)
{
  (void)mrb; (void)self;
  return mrb_nil_value();
}
#endif

static void
jamstack_bridge_init(mrb_state *mrb)
{
  struct RClass *m = mrb_define_module(mrb, "Jamstack");
  mrb_define_module_function(mrb, m, "__cap_begin", js_cap_begin, MRB_ARGS_NONE());
  mrb_define_module_function(mrb, m, "__cap_end",   js_cap_end,   MRB_ARGS_NONE());
  mrb_define_module_function(mrb, m, "getenv",      js_getenv,    MRB_ARGS_REQ(1));
  mrb_define_module_function(mrb, m, "eval_js",     jamstack_eval_js, MRB_ARGS_REQ(1));
}

#ifdef __EMSCRIPTEN__
/* Web eval entry: JS calls
 *   Module.ccall('jamstack_eval','string',['string'],[code])
 * Runs Jamstack::Bridge.eval_json on the persistent g_mrb (main never returns on
 * web — set_main_loop unwinds — so g_mrb stays alive). Single-threaded, so a direct
 * call between frames is main-thread-safe (no queue needed). The caller need not
 * free; the previous result is freed on the next call. */
EMSCRIPTEN_KEEPALIVE
char *
jamstack_eval(const char *code)
{
  static char *last = NULL;
  if (last) { free(last); last = NULL; }
  if (!g_mrb || !code) return NULL;
  mrb_state *mrb = g_mrb;
  int ai = mrb_gc_arena_save(mrb);
  struct RClass *js = mrb_module_get(mrb, "Jamstack");
  mrb_value bridge = mrb_const_get(mrb, mrb_obj_value(js), mrb_intern_lit(mrb, "Bridge"));
  mrb_value r = mrb_funcall(mrb, bridge, "eval_json", 1, mrb_str_new_cstr(mrb, code));
  char *out = NULL;
  if (mrb_string_p(r)) {
    mrb_int n = RSTRING_LEN(r);
    out = (char *)malloc((size_t)n + 1);
    if (out) { memcpy(out, RSTRING_PTR(r), (size_t)n); out[n] = '\0'; }
  }
  if (mrb->exc) mrb->exc = NULL;   /* eval_json shouldn't raise; be safe */
  mrb_gc_arena_restore(mrb, ai);
  last = out;
  return out;
}
#endif

int
main(int argc, char **argv)
{
  const char *script = (argc > 1) ? argv[1] : "game/main.rb";

  mrb_state *mrb = mrb_open();
  if (!mrb) { fprintf(stderr, "failed to open mruby\n"); return 1; }

  g_mrb = mrb;
  jamstack_bridge_init(mrb);

  /* Expose argv[2..] as Ruby ARGV constant (Phase 2: study-player audio file). */
  {
    mrb_value argv_ary = mrb_ary_new(mrb);
    for (int i = 2; i < argc; i++) {
      mrb_ary_push(mrb, argv_ary, mrb_str_new_cstr(mrb, argv[i]));
    }
    mrb_define_const(mrb, mrb->object_class, "ARGV", argv_ary);
  }

  size_t len = 0;
  char *src = read_file(script, &len);
  if (!src) { mrb_close(mrb); return 1; }

  mrbc_context *cxt = mrbc_context_new(mrb);
  mrbc_filename(mrb, cxt, script);

  mrb_load_string_cxt(mrb, src, cxt);

  int rc = 0;
  if (mrb->exc) {
    mrb_print_error(mrb);
    rc = 1;
  }

  mrbc_context_free(mrb, cxt);
  free(src);
  mrb_close(mrb);
  return rc;
}

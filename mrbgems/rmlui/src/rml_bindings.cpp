/* RmlUi <-> mruby bindings + raylib (rlgl) render/system backend.
 *
 * Minimal milestone: initialize RmlUi against raylib's GL context, create a
 * context, load + show a static .rml document, update/render it over the game,
 * and feed raylib mouse input. Data binding comes next.
 *
 * The render interface is implemented against rlgl (raylib's GL abstraction) so
 * the same code path works on desktop GL and (later) WebGL under emscripten.
 */
#include <mruby.h>
#include <mruby/string.h>
#include <mruby/data.h>
#include <mruby/array.h>
#include <mruby/gc.h>

#include <RmlUi/Core.h>
#include <raylib.h>
#include <rlgl.h>

#include <vector>
#include <string>
#include <cstring>
#include <set>

using namespace Rml;

/* ------------------------------------------------------------------ */
/* Render interface (rlgl)                                             */
/* ------------------------------------------------------------------ */
namespace {

struct RlGeometry {
  std::vector<Vertex> vertices;
  std::vector<int> indices;
};

class RaylibRenderInterface : public Rml::RenderInterface {
public:
  CompiledGeometryHandle CompileGeometry(Span<const Vertex> vertices, Span<const int> indices) override
  {
    RlGeometry *geo = new RlGeometry();
    geo->vertices.assign(vertices.begin(), vertices.end());
    geo->indices.assign(indices.begin(), indices.end());
    return (CompiledGeometryHandle)geo;
  }

  void RenderGeometry(CompiledGeometryHandle handle, Vector2f translation, TextureHandle texture) override
  {
    RlGeometry *geo = (RlGeometry *)handle;
    unsigned int tex = texture ? (unsigned int)texture : rlGetTextureIdDefault();

    // IMPORTANT: rlBegin() resets the draw group's texture to the default texture
    // on a draw-mode change, so rlSetTexture() MUST be called AFTER rlBegin().
    // (raylib's own DrawTexture* only works set-then-begin because everything is
    // already RL_QUADS and no mode change occurs.)
    rlBegin(RL_TRIANGLES);
    rlSetTexture(tex);
    for (int idx : geo->indices) {
      const Vertex &v = geo->vertices[(size_t)idx];
      // Apply the element transform (SetTransform) to the translated vertex,
      // then perspective-divide. RmlUi passes the local transform via
      // SetTransform and the element's screen position via `translation`
      // (matching GL2's modelview = transform * translate(v)). When no
      // transform is set (nullptr) we fall back to the raw translated point,
      // so non-transformed elements render exactly as before.
      float x = v.position.x + translation.x;
      float y = v.position.y + translation.y;
      if (m_has_transform) {
        Rml::Vector4f tp = m_transform * Rml::Vector4f(x, y, 0.0f, 1.0f);
        float w = tp.w;
        if (w != 0.0f) { x = tp.x / w; y = tp.y / w; }
        else { x = tp.x; y = tp.y; }
      }
      rlColor4ub(v.colour.red, v.colour.green, v.colour.blue, v.colour.alpha);
      rlTexCoord2f(v.tex_coord.x, v.tex_coord.y);
      rlVertex2f(x, y);
    }
    rlEnd();
    // Flush each geometry as its own draw. rlgl's batch is quad-centric and pads
    // RL_TRIANGLES vertex runs for quad-index alignment; letting multiple glyph
    // runs (different textures) accumulate corrupts geometry across draw groups.
    rlSetTexture(0);
    rlDrawRenderBatchActive();
  }

  void ReleaseGeometry(CompiledGeometryHandle handle) override
  {
    delete (RlGeometry *)handle;
  }

  TextureHandle LoadTexture(Vector2i &dims, const String &source) override
  {
    Image img = LoadImage(source.c_str());
    if (img.data == nullptr) return 0;
    ImageFormat(&img, RL_PIXELFORMAT_UNCOMPRESSED_R8G8B8A8);
    dims.x = img.width;
    dims.y = img.height;
    unsigned int id = rlLoadTexture(img.data, img.width, img.height,
                                    RL_PIXELFORMAT_UNCOMPRESSED_R8G8B8A8, 1);
    UnloadImage(img);
    return (TextureHandle)id;
  }

  TextureHandle GenerateTexture(Span<const byte> source, Vector2i dims) override
  {
    // RmlUi 6.x renders with premultiplied alpha. The font/image atlas data here
    // is straight (non-premultiplied) RGBA (RGB=255 where alpha=coverage), so we
    // premultiply on upload; otherwise premult blending makes the area outside
    // each glyph additive and fills the whole quad (solid squares).
    // RmlUi 6.x already supplies premultiplied-alpha RGBA, upload as-is.
    unsigned int id = rlLoadTexture(source.data(), dims.x, dims.y,
                                    RL_PIXELFORMAT_UNCOMPRESSED_R8G8B8A8, 1);
    return (TextureHandle)id;
  }

  void ReleaseTexture(TextureHandle texture) override
  {
    rlUnloadTexture((unsigned int)texture);
  }

  // Stores the element's local transform (includes transform-origin baking and
  // any perspective()/rotate3d()). Applied per-vertex in RenderGeometry with a
  // perspective divide, mirroring RmlUi's GL2 reference backend (modelview =
  // transform * translate(v)). nullptr => identity (render raw, as before).
  void SetTransform(const Rml::Matrix4f* transform) override
  {
    if (transform) { m_transform = *transform; m_has_transform = true; }
    else m_has_transform = false;
  }

  void EnableScissorRegion(bool enable) override
  {
    rlDrawRenderBatchActive();
    if (enable) rlEnableScissorTest();
    else rlDisableScissorTest();
  }

  void SetScissorRegion(Rectanglei region) override
  {
    rlDrawRenderBatchActive();
    int h = region.Height();
    int top = region.Position().y;
    int y = GetScreenHeight() - (top + h); /* GL scissor is bottom-left origin */
    rlScissor(region.Position().x, y, region.Width(), h);
  }

private:
  Rml::Matrix4f m_transform;
  bool m_has_transform = false;
};

class RaylibSystemInterface : public Rml::SystemInterface {
public:
  double GetElapsedTime() override { return GetTime(); }
  bool LogMessage(Log::Type type, const String &message) override
  {
    int level = (type == Log::LT_ERROR || type == Log::LT_ASSERT) ? LOG_WARNING : LOG_INFO;
    TraceLog(level, "RmlUi: %s", message.c_str());
    return true;
  }
};

RaylibRenderInterface *g_render = nullptr;
RaylibSystemInterface *g_system = nullptr;

/* ------------------------------------------------------------------ */
/* Data binding bridge (Ruby <-> RmlUi data model)                     */
/* ------------------------------------------------------------------ */

struct ModelSession {
  mrb_state *mrb;
  mrb_value ruby_model;            /* the Ruby Rml::DataModel instance */
  DataModelConstructor *ctor;      /* alive only during construction */
  DataModelHandle handle;
};

static Variant ruby_to_variant(mrb_state *mrb, mrb_value v)
{
  switch (mrb_type(v)) {
    case MRB_TT_INTEGER: return Variant((int)mrb_integer(v));
    case MRB_TT_FLOAT:   return Variant((float)mrb_float(v));
    case MRB_TT_TRUE:    return Variant(true);
    case MRB_TT_FALSE:   return Variant(false);
    case MRB_TT_STRING:  return Variant(String(mrb_string_cstr(mrb, v)));
    case MRB_TT_SYMBOL:  return Variant(String(mrb_sym_name(mrb, mrb_symbol(v))));
    default: {
      mrb_value s = mrb_funcall(mrb, v, "to_s", 0);
      return Variant(String(mrb_string_cstr(mrb, s)));
    }
  }
}

static mrb_value variant_to_ruby(mrb_state *mrb, const Variant &var)
{
  switch (var.GetType()) {
    case Variant::BOOL:
      return mrb_bool_value(var.Get<bool>());
    case Variant::INT: case Variant::INT64:
    case Variant::UINT: case Variant::UINT64:
    case Variant::BYTE: case Variant::CHAR:
      return mrb_fixnum_value(var.Get<int>());
    case Variant::FLOAT: case Variant::DOUBLE:
      return mrb_float_value(mrb, var.Get<double>());
    default:
      return mrb_str_new_cstr(mrb, var.Get<String>().c_str());
  }
}

} /* anonymous namespace */

/* ------------------------------------------------------------------ */
/* mruby bindings (low-level Rml._* primitives)                        */
/* ------------------------------------------------------------------ */

static mrb_value
rml_init(mrb_state *mrb, mrb_value self)
{
  if (g_render == nullptr) {
    g_render = new RaylibRenderInterface();
    g_system = new RaylibSystemInterface();
    Rml::SetSystemInterface(g_system);
    Rml::SetRenderInterface(g_render);
    Rml::Initialise();
  }
  return mrb_nil_value();
}

static mrb_value
rml_shutdown(mrb_state *mrb, mrb_value self)
{
  if (g_render != nullptr) {
    Rml::Shutdown();
    delete g_render; g_render = nullptr;
    delete g_system; g_system = nullptr;
  }
  return mrb_nil_value();
}

static mrb_value
rml_load_font(mrb_state *mrb, mrb_value self)
{
  const char *path;
  mrb_bool fallback = FALSE;
  mrb_get_args(mrb, "z|b", &path, &fallback);
  bool ok = Rml::LoadFontFace(path, fallback);
  return mrb_bool_value(ok);
}

static mrb_value
rml_create_context(mrb_state *mrb, mrb_value self)
{
  const char *name;
  mrb_int w, h;
  mrb_get_args(mrb, "zii", &name, &w, &h);
  Context *ctx = Rml::CreateContext(name, Vector2i((int)w, (int)h));
  if (!ctx) return mrb_nil_value();
  return mrb_cptr_value(mrb, ctx);
}

static Context *
ctx_arg(mrb_state *mrb)
{
  mrb_value p;
  mrb_get_args(mrb, "o", &p);
  return (Context *)mrb_cptr(p);
}

static mrb_value
rml_context_set_dimensions(mrb_state *mrb, mrb_value self)
{
  mrb_value p; mrb_int w, h;
  mrb_get_args(mrb, "oii", &p, &w, &h);
  ((Context *)mrb_cptr(p))->SetDimensions(Vector2i((int)w, (int)h));
  return mrb_nil_value();
}

/* ------------------------------------------------------------------ */
/* Keyboard input: raylib -> RmlUi key map + modifier state            */
/* (closes the input gap that blocked the in-game console, roadmap R6) */
/* ------------------------------------------------------------------ */

/* raylib KeyboardKey -> RmlUi Input::KeyIdentifier. OEM punctuation keys
 * (;',./etc.) deliberately return KI_UNKNOWN — those arrive via
 * GetCharPressed -> ProcessTextInput (the character codepoint path), which is
 * how RmlUi's own GLFW backend handles them too. */
static Input::KeyIdentifier rl_key_to_rml(int key)
{
  switch (key) {
    case KEY_SPACE:           return Input::KI_SPACE;
    case KEY_APOSTROPHE:      return Input::KI_OEM_7;      /* ' " */
    case KEY_COMMA:           return Input::KI_OEM_COMMA;
    case KEY_MINUS:           return Input::KI_OEM_MINUS;
    case KEY_PERIOD:          return Input::KI_OEM_PERIOD;
    case KEY_SLASH:           return Input::KI_OEM_2;      /* / ? */
    case KEY_ZERO:            return Input::KI_0;
    case KEY_ONE:             return Input::KI_1;
    case KEY_TWO:             return Input::KI_2;
    case KEY_THREE:           return Input::KI_3;
    case KEY_FOUR:            return Input::KI_4;
    case KEY_FIVE:            return Input::KI_5;
    case KEY_SIX:             return Input::KI_6;
    case KEY_SEVEN:           return Input::KI_7;
    case KEY_EIGHT:           return Input::KI_8;
    case KEY_NINE:            return Input::KI_9;
    case KEY_SEMICOLON:       return Input::KI_OEM_1;
    case KEY_EQUAL:           return Input::KI_OEM_PLUS;
    case KEY_A:               return Input::KI_A;
    case KEY_B:               return Input::KI_B;
    case KEY_C:               return Input::KI_C;
    case KEY_D:               return Input::KI_D;
    case KEY_E:               return Input::KI_E;
    case KEY_F:               return Input::KI_F;
    case KEY_G:               return Input::KI_G;
    case KEY_H:               return Input::KI_H;
    case KEY_I:               return Input::KI_I;
    case KEY_J:               return Input::KI_J;
    case KEY_K:               return Input::KI_K;
    case KEY_L:               return Input::KI_L;
    case KEY_M:               return Input::KI_M;
    case KEY_N:               return Input::KI_N;
    case KEY_O:               return Input::KI_O;
    case KEY_P:               return Input::KI_P;
    case KEY_Q:               return Input::KI_Q;
    case KEY_R:               return Input::KI_R;
    case KEY_S:               return Input::KI_S;
    case KEY_T:               return Input::KI_T;
    case KEY_U:               return Input::KI_U;
    case KEY_V:               return Input::KI_V;
    case KEY_W:               return Input::KI_W;
    case KEY_X:               return Input::KI_X;
    case KEY_Y:               return Input::KI_Y;
    case KEY_Z:               return Input::KI_Z;
    case KEY_LEFT_BRACKET:    return Input::KI_OEM_4;      /* [ { */
    case KEY_BACKSLASH:       return Input::KI_OEM_5;      /* \ | */
    case KEY_RIGHT_BRACKET:   return Input::KI_OEM_6;     /* ] } */
    case KEY_GRAVE:           return Input::KI_OEM_3;      /* ` ~ */
    case KEY_BACKSPACE:       return Input::KI_BACK;
    case KEY_TAB:             return Input::KI_TAB;
    case KEY_ENTER:           return Input::KI_RETURN;
    case KEY_ESCAPE:          return Input::KI_ESCAPE;
    case KEY_INSERT:          return Input::KI_INSERT;
    case KEY_DELETE:          return Input::KI_DELETE;
    case KEY_RIGHT:           return Input::KI_RIGHT;
    case KEY_LEFT:            return Input::KI_LEFT;
    case KEY_DOWN:            return Input::KI_DOWN;
    case KEY_UP:              return Input::KI_UP;
    case KEY_PAGE_UP:         return Input::KI_PRIOR;
    case KEY_PAGE_DOWN:       return Input::KI_NEXT;
    case KEY_HOME:            return Input::KI_HOME;
    case KEY_END:             return Input::KI_END;
    case KEY_CAPS_LOCK:       return Input::KI_CAPITAL;
    case KEY_F1:              return Input::KI_F1;
    case KEY_F2:              return Input::KI_F2;
    case KEY_F3:              return Input::KI_F3;
    case KEY_F4:              return Input::KI_F4;
    case KEY_F5:              return Input::KI_F5;
    case KEY_F6:              return Input::KI_F6;
    case KEY_F7:              return Input::KI_F7;
    case KEY_F8:              return Input::KI_F8;
    case KEY_F9:              return Input::KI_F9;
    case KEY_F10:             return Input::KI_F10;
    case KEY_F11:             return Input::KI_F11;
    case KEY_F12:             return Input::KI_F12;
    case KEY_LEFT_SHIFT:      return Input::KI_LSHIFT;
    case KEY_RIGHT_SHIFT:     return Input::KI_RSHIFT;
    case KEY_LEFT_CONTROL:    return Input::KI_LCONTROL;
    case KEY_RIGHT_CONTROL:   return Input::KI_RCONTROL;
    case KEY_LEFT_ALT:        return Input::KI_LMENU;
    case KEY_RIGHT_ALT:       return Input::KI_RMENU;
    case KEY_LEFT_SUPER:      return Input::KI_LWIN;
    case KEY_RIGHT_SUPER:     return Input::KI_RWIN;
    default:                  return Input::KI_UNKNOWN;
  }
}

/* raylib modifier key state -> RmlUi KeyModifier bitmask. */
static int rl_key_modifiers(void)
{
  int m = 0;
  if (IsKeyDown(KEY_LEFT_CONTROL) || IsKeyDown(KEY_RIGHT_CONTROL)) m |= Input::KM_CTRL;
  if (IsKeyDown(KEY_LEFT_SHIFT)    || IsKeyDown(KEY_RIGHT_SHIFT))    m |= Input::KM_SHIFT;
  if (IsKeyDown(KEY_LEFT_ALT)     || IsKeyDown(KEY_RIGHT_ALT))       m |= Input::KM_ALT;
  if (IsKeyDown(KEY_LEFT_SUPER)   || IsKeyDown(KEY_RIGHT_SUPER))     m |= Input::KM_META;
  return m;
}

/* Keys currently down from RmlUi's perspective. raylib's GetKeyPressed() only
 * reports press-edges (a queue); IsKeyReleased(k) is true for one frame on
 * release, so we track the down-set to know which keys to check for release. */
static std::set<int> g_rml_down_keys;

static mrb_value
rml_context_update(mrb_state *mrb, mrb_value self)
{
  ctx_arg(mrb)->Update();
  return mrb_nil_value();
}

static mrb_value
rml_context_render(mrb_state *mrb, mrb_value self)
{
  Context *ctx = ctx_arg(mrb);
  rlDrawRenderBatchActive();
  rlSetBlendMode(RL_BLEND_ALPHA_PREMULTIPLY); /* RmlUi uses premultiplied alpha */
  ctx->Render();
  rlDrawRenderBatchActive();
  rlSetBlendMode(RL_BLEND_ALPHA);
  return mrb_nil_value();
}

static mrb_value
rml_context_process_input(mrb_state *mrb, mrb_value self)
{
  Context *ctx = ctx_arg(mrb);
  ctx->ProcessMouseMove(GetMouseX(), GetMouseY(), 0);
  if (IsMouseButtonPressed(MOUSE_BUTTON_LEFT))  ctx->ProcessMouseButtonDown(0, 0);
  if (IsMouseButtonReleased(MOUSE_BUTTON_LEFT)) ctx->ProcessMouseButtonUp(0, 0);

  /* --- keyboard input (closes the RmlUi input gap; was mouse-only) ---
   * raylib's GetKeyPressed() drains a queue of press-edge events (returns 0 when
   * empty); IsKeyReleased(k) is true for exactly one frame on release. We track
   * the down-set ourselves to synthesize ProcessKeyUp, since raylib has no
   * "what was released?" queue. GetCharPressed() yields Unicode codepoints for
   * text input (already respects shift/capslock); OEM keys (;',./etc.) are
   * delivered through this path, not through KI_* codes. */
  int mods = rl_key_modifiers();
  while (int k = GetKeyPressed()) {
    g_rml_down_keys.insert(k);
    Input::KeyIdentifier ki = rl_key_to_rml(k);
    if (ki != Input::KI_UNKNOWN)
      ctx->ProcessKeyDown(ki, mods);
  }
  for (auto it = g_rml_down_keys.begin(); it != g_rml_down_keys.end(); ) {
    if (IsKeyReleased(*it)) {
      Input::KeyIdentifier ki = rl_key_to_rml(*it);
      if (ki != Input::KI_UNKNOWN)
        ctx->ProcessKeyUp(ki, mods);
      it = g_rml_down_keys.erase(it);
    } else {
      ++it;
    }
  }
  while (int c = GetCharPressed()) {
    if (c >= 32 && c != 127)   /* printable; skip control chars (handled as keys) */
      ctx->ProcessTextInput((Character)c);
  }
  return mrb_nil_value();
}

static mrb_value
rml_context_load_document(mrb_state *mrb, mrb_value self)
{
  mrb_value p;
  const char *path;
  mrb_get_args(mrb, "oz", &p, &path);
  ElementDocument *doc = ((Context *)mrb_cptr(p))->LoadDocument(path);
  if (!doc) return mrb_nil_value();
  return mrb_cptr_value(mrb, doc);
}

static mrb_value
rml_document_show(mrb_state *mrb, mrb_value self)
{
  mrb_value p;
  mrb_get_args(mrb, "o", &p);
  ((ElementDocument *)mrb_cptr(p))->Show();
  return mrb_nil_value();
}

static mrb_value
rml_document_hide(mrb_state *mrb, mrb_value self)
{
  mrb_value p;
  mrb_get_args(mrb, "o", &p);
  ((ElementDocument *)mrb_cptr(p))->Hide();
  return mrb_nil_value();
}

/* ================================================================== */
/* Element / Event / Document — comprehensive bindings                 */
/* (modeled on RmlUi's Lua bindings)                                   */
/* ================================================================== */

static Element *el_arg(mrb_state *mrb)
{
  mrb_value p; mrb_get_args(mrb, "o", &p);
  return (Element *)mrb_cptr(p);
}

/* wrap an Element* as a Ruby Rml::Element (or nil) */
static mrb_value wrap_element(mrb_state *mrb, Element *e)
{
  if (!e) return mrb_nil_value();
  struct RClass *m = mrb_module_get(mrb, "Rml");
  struct RClass *c = mrb_class_get_under(mrb, m, "Element");
  return mrb_funcall(mrb, mrb_obj_value(c), "new", 1, mrb_cptr_value(mrb, e));
}

static mrb_value wrap_element_list(mrb_state *mrb, const ElementList &list)
{
  mrb_value arr = mrb_ary_new_capa(mrb, (mrb_int)list.size());
  for (Element *e : list) mrb_ary_push(mrb, arr, wrap_element(mrb, e));
  return arr;
}

/* Event listener that dispatches to a stored Ruby block. */
class RubyEventListener : public EventListener {
public:
  RubyEventListener(mrb_state *m, mrb_value blk) : mrb(m), block(blk) { mrb_gc_register(m, blk); }
  void ProcessEvent(Event &event) override
  {
    struct RClass *m = mrb_module_get(mrb, "Rml");
    struct RClass *c = mrb_class_get_under(mrb, m, "Event");
    mrb_value ev = mrb_funcall(mrb, mrb_obj_value(c), "new", 1, mrb_cptr_value(mrb, &event));
    mrb_yield(mrb, block, ev);
  }
private:
  mrb_state *mrb;
  mrb_value block;
};

/* --- attributes --- */
static mrb_value rml_el_get_attribute(mrb_state *mrb, mrb_value self) {
  mrb_value p; const char *name; mrb_get_args(mrb, "oz", &p, &name);
  Variant *v = ((Element *)mrb_cptr(p))->GetAttribute(name);
  return v ? mrb_str_new_cstr(mrb, v->Get<String>().c_str()) : mrb_nil_value();
}
static mrb_value rml_el_set_attribute(mrb_state *mrb, mrb_value self) {
  mrb_value p; const char *name, *val; mrb_get_args(mrb, "ozz", &p, &name, &val);
  ((Element *)mrb_cptr(p))->SetAttribute(name, String(val));
  return mrb_nil_value();
}
static mrb_value rml_el_has_attribute(mrb_state *mrb, mrb_value self) {
  mrb_value p; const char *name; mrb_get_args(mrb, "oz", &p, &name);
  return mrb_bool_value(((Element *)mrb_cptr(p))->HasAttribute(name));
}
static mrb_value rml_el_remove_attribute(mrb_state *mrb, mrb_value self) {
  mrb_value p; const char *name; mrb_get_args(mrb, "oz", &p, &name);
  ((Element *)mrb_cptr(p))->RemoveAttribute(name);
  return mrb_nil_value();
}

/* --- id / tag / rml --- */
static mrb_value rml_el_get_id(mrb_state *mrb, mrb_value self) {
  return mrb_str_new_cstr(mrb, el_arg(mrb)->GetId().c_str());
}
static mrb_value rml_el_set_id(mrb_state *mrb, mrb_value self) {
  mrb_value p; const char *v; mrb_get_args(mrb, "oz", &p, &v);
  ((Element *)mrb_cptr(p))->SetId(v); return mrb_nil_value();
}
static mrb_value rml_el_tag(mrb_state *mrb, mrb_value self) {
  return mrb_str_new_cstr(mrb, el_arg(mrb)->GetTagName().c_str());
}
static mrb_value rml_el_get_inner_rml(mrb_state *mrb, mrb_value self) {
  return mrb_str_new_cstr(mrb, el_arg(mrb)->GetInnerRML().c_str());
}
static mrb_value rml_el_set_inner_rml(mrb_state *mrb, mrb_value self) {
  mrb_value p; const char *v; mrb_get_args(mrb, "oz", &p, &v);
  ((Element *)mrb_cptr(p))->SetInnerRML(v); return mrb_nil_value();
}

/* --- classes / properties --- */
static mrb_value rml_el_set_class(mrb_state *mrb, mrb_value self) {
  mrb_value p; const char *name; mrb_bool on; mrb_get_args(mrb, "ozb", &p, &name, &on);
  ((Element *)mrb_cptr(p))->SetClass(name, on); return mrb_nil_value();
}
static mrb_value rml_el_is_class_set(mrb_state *mrb, mrb_value self) {
  mrb_value p; const char *name; mrb_get_args(mrb, "oz", &p, &name);
  return mrb_bool_value(((Element *)mrb_cptr(p))->IsClassSet(name));
}
static mrb_value rml_el_set_property(mrb_state *mrb, mrb_value self) {
  mrb_value p; const char *name, *val; mrb_get_args(mrb, "ozz", &p, &name, &val);
  return mrb_bool_value(((Element *)mrb_cptr(p))->SetProperty(name, val));
}
static mrb_value rml_el_get_property(mrb_state *mrb, mrb_value self) {
  mrb_value p; const char *name; mrb_get_args(mrb, "oz", &p, &name);
  const Property *prop = ((Element *)mrb_cptr(p))->GetProperty(name);
  return prop ? mrb_str_new_cstr(mrb, prop->ToString().c_str()) : mrb_nil_value();
}
static mrb_value rml_el_remove_property(mrb_state *mrb, mrb_value self) {
  mrb_value p; const char *name; mrb_get_args(mrb, "oz", &p, &name);
  ((Element *)mrb_cptr(p))->RemoveProperty(name); return mrb_nil_value();
}

/* --- actions --- */
static mrb_value rml_el_focus(mrb_state *mrb, mrb_value self) { el_arg(mrb)->Focus(); return mrb_nil_value(); }
static mrb_value rml_el_blur(mrb_state *mrb, mrb_value self) { el_arg(mrb)->Blur(); return mrb_nil_value(); }
static mrb_value rml_el_click(mrb_state *mrb, mrb_value self) { el_arg(mrb)->Click(); return mrb_nil_value(); }
static mrb_value rml_el_scroll_into_view(mrb_state *mrb, mrb_value self) {
  mrb_value p; mrb_bool top = TRUE; mrb_get_args(mrb, "o|b", &p, &top);
  ((Element *)mrb_cptr(p))->ScrollIntoView(top); return mrb_nil_value();
}
static mrb_value rml_el_select(mrb_state *mrb, mrb_value self) {
  auto *el = el_arg(mrb);
  auto *input = dynamic_cast<ElementFormControlInput *>(el);
  if (input) input->Select();
  return mrb_nil_value();
}
static mrb_value rml_el_set_selection_range(mrb_state *mrb, mrb_value self) {
  mrb_value p; mrb_int start, end;
  mrb_get_args(mrb, "oii", &p, &start, &end);
  auto *input = dynamic_cast<ElementFormControlInput *>((Element *)mrb_cptr(p));
  if (input) input->SetSelectionRange((int)start, (int)end);
  return mrb_nil_value();
}
static mrb_value rml_el_is_visible(mrb_state *mrb, mrb_value self) {
  return mrb_bool_value(el_arg(mrb)->IsVisible());
}

/* --- traversal / queries --- */
static mrb_value rml_el_get_element_by_id(mrb_state *mrb, mrb_value self) {
  mrb_value p; const char *id; mrb_get_args(mrb, "oz", &p, &id);
  return wrap_element(mrb, ((Element *)mrb_cptr(p))->GetElementById(id));
}
static mrb_value rml_el_query_selector(mrb_state *mrb, mrb_value self) {
  mrb_value p; const char *sel; mrb_get_args(mrb, "oz", &p, &sel);
  return wrap_element(mrb, ((Element *)mrb_cptr(p))->QuerySelector(sel));
}
static mrb_value rml_el_query_selector_all(mrb_state *mrb, mrb_value self) {
  mrb_value p; const char *sel; mrb_get_args(mrb, "oz", &p, &sel);
  ElementList list; ((Element *)mrb_cptr(p))->QuerySelectorAll(list, sel);
  return wrap_element_list(mrb, list);
}
static mrb_value rml_el_get_elements_by_tag(mrb_state *mrb, mrb_value self) {
  mrb_value p; const char *tag; mrb_get_args(mrb, "oz", &p, &tag);
  ElementList list; ((Element *)mrb_cptr(p))->GetElementsByTagName(list, tag);
  return wrap_element_list(mrb, list);
}
static mrb_value rml_el_parent(mrb_state *mrb, mrb_value self) {
  return wrap_element(mrb, el_arg(mrb)->GetParentNode());
}
static mrb_value rml_el_num_children(mrb_state *mrb, mrb_value self) {
  return mrb_fixnum_value(el_arg(mrb)->GetNumChildren());
}
static mrb_value rml_el_child(mrb_state *mrb, mrb_value self) {
  mrb_value p; mrb_int i; mrb_get_args(mrb, "oi", &p, &i);
  return wrap_element(mrb, ((Element *)mrb_cptr(p))->GetChild((int)i));
}
static mrb_value rml_el_owner_document(mrb_state *mrb, mrb_value self) {
  return wrap_element(mrb, el_arg(mrb)->GetOwnerDocument());
}

/* --- geometry --- */
static mrb_value rml_el_client_width(mrb_state *mrb, mrb_value self) { return mrb_float_value(mrb, el_arg(mrb)->GetClientWidth()); }
static mrb_value rml_el_client_height(mrb_state *mrb, mrb_value self) { return mrb_float_value(mrb, el_arg(mrb)->GetClientHeight()); }
static mrb_value rml_el_offset_left(mrb_state *mrb, mrb_value self) { return mrb_float_value(mrb, el_arg(mrb)->GetOffsetLeft()); }
static mrb_value rml_el_offset_top(mrb_state *mrb, mrb_value self) { return mrb_float_value(mrb, el_arg(mrb)->GetOffsetTop()); }
static mrb_value rml_el_absolute_left(mrb_state *mrb, mrb_value self) { return mrb_float_value(mrb, el_arg(mrb)->GetAbsoluteLeft()); }
static mrb_value rml_el_absolute_top(mrb_state *mrb, mrb_value self) { return mrb_float_value(mrb, el_arg(mrb)->GetAbsoluteTop()); }

/* --- events --- */
static mrb_value rml_el_add_event_listener(mrb_state *mrb, mrb_value self) {
  mrb_value p, blk; const char *type;
  mrb_get_args(mrb, "oz&", &p, &type, &blk);
  ((Element *)mrb_cptr(p))->AddEventListener(type, new RubyEventListener(mrb, blk));
  return mrb_nil_value();
}

/* --- Event accessors --- */
static Event *ev_arg(mrb_state *mrb) { mrb_value p; mrb_get_args(mrb, "o", &p); return (Event *)mrb_cptr(p); }
static mrb_value rml_ev_type(mrb_state *mrb, mrb_value self) { return mrb_str_new_cstr(mrb, ev_arg(mrb)->GetType().c_str()); }
static mrb_value rml_ev_target(mrb_state *mrb, mrb_value self) { return wrap_element(mrb, ev_arg(mrb)->GetTargetElement()); }
static mrb_value rml_ev_current(mrb_state *mrb, mrb_value self) { return wrap_element(mrb, ev_arg(mrb)->GetCurrentElement()); }
static mrb_value rml_ev_stop_propagation(mrb_state *mrb, mrb_value self) { ev_arg(mrb)->StopPropagation(); return mrb_nil_value(); }
static mrb_value rml_ev_stop_immediate(mrb_state *mrb, mrb_value self) { ev_arg(mrb)->StopImmediatePropagation(); return mrb_nil_value(); }
static mrb_value rml_ev_param_float(mrb_state *mrb, mrb_value self) {
  mrb_value p; const char *k; mrb_get_args(mrb, "oz", &p, &k);
  return mrb_float_value(mrb, ((Event *)mrb_cptr(p))->GetParameter<float>(k, 0.0f));
}
static mrb_value rml_ev_param_str(mrb_state *mrb, mrb_value self) {
  mrb_value p; const char *k; mrb_get_args(mrb, "oz", &p, &k);
  return mrb_str_new_cstr(mrb, ((Event *)mrb_cptr(p))->GetParameter<String>(k, String()).c_str());
}

/* --- Document (ElementDocument*) --- */
static ElementDocument *doc_arg(mrb_state *mrb) { mrb_value p; mrb_get_args(mrb, "o", &p); return (ElementDocument *)mrb_cptr(p); }
static mrb_value rml_doc_title(mrb_state *mrb, mrb_value self) { return mrb_str_new_cstr(mrb, doc_arg(mrb)->GetTitle().c_str()); }
static mrb_value rml_doc_set_title(mrb_state *mrb, mrb_value self) {
  mrb_value p; const char *t; mrb_get_args(mrb, "oz", &p, &t);
  ((ElementDocument *)mrb_cptr(p))->SetTitle(t); return mrb_nil_value();
}
static mrb_value rml_doc_pull_to_front(mrb_state *mrb, mrb_value self) { doc_arg(mrb)->PullToFront(); return mrb_nil_value(); }
static mrb_value rml_doc_push_to_back(mrb_state *mrb, mrb_value self) { doc_arg(mrb)->PushToBack(); return mrb_nil_value(); }
static mrb_value rml_doc_close(mrb_state *mrb, mrb_value self) { doc_arg(mrb)->Close(); return mrb_nil_value(); }

/* --- Context document accessors --- */
static mrb_value rml_context_get_document(mrb_state *mrb, mrb_value self) {
  mrb_value p; const char *id; mrb_get_args(mrb, "oz", &p, &id);
  return wrap_element(mrb, ((Context *)mrb_cptr(p))->GetDocument(id));
}
static mrb_value rml_context_num_documents(mrb_state *mrb, mrb_value self) {
  mrb_value p; mrb_get_args(mrb, "o", &p);
  return mrb_fixnum_value(((Context *)mrb_cptr(p))->GetNumDocuments());
}

/* --- data model --- */

static mrb_value
rml_data_model_create(mrb_state *mrb, mrb_value self)
{
  mrb_value ctxp, model;
  const char *name;
  mrb_get_args(mrb, "ozo", &ctxp, &name, &model);
  Context *ctx = (Context *)mrb_cptr(ctxp);
  ModelSession *s = new ModelSession();
  s->mrb = mrb;
  s->ruby_model = model;
  s->ctor = new DataModelConstructor(ctx->CreateDataModel(name));
  mrb_gc_register(mrb, model); /* keep the Ruby model alive for callbacks */
  return mrb_cptr_value(mrb, s);
}

/* read-only computed binding: getter dispatches to ruby model.__get(name) */
static mrb_value
rml_data_model_bind_get(mrb_state *mrb, mrb_value self)
{
  mrb_value sp; const char *name;
  mrb_get_args(mrb, "oz", &sp, &name);
  ModelSession *s = (ModelSession *)mrb_cptr(sp);
  std::string nm = name;
  mrb_state *m = s->mrb; mrb_value model = s->ruby_model;
  s->ctor->BindFunc(nm, [m, model, nm](Variant &out) {
    mrb_value r = mrb_funcall(m, model, "__get", 1, mrb_str_new_cstr(m, nm.c_str()));
    out = ruby_to_variant(m, r);
  });
  return mrb_nil_value();
}

/* two-way scalar: getter + setter dispatch to ruby model.__get/__set */
static mrb_value
rml_data_model_bind_scalar(mrb_state *mrb, mrb_value self)
{
  mrb_value sp; const char *name;
  mrb_get_args(mrb, "oz", &sp, &name);
  ModelSession *s = (ModelSession *)mrb_cptr(sp);
  std::string nm = name;
  mrb_state *m = s->mrb; mrb_value model = s->ruby_model;
  s->ctor->BindFunc(nm,
    [m, model, nm](Variant &out) {
      mrb_value r = mrb_funcall(m, model, "__get", 1, mrb_str_new_cstr(m, nm.c_str()));
      out = ruby_to_variant(m, r);
    },
    [m, model, nm](const Variant &in) {
      mrb_funcall(m, model, "__set", 2, mrb_str_new_cstr(m, nm.c_str()), variant_to_ruby(m, in));
    });
  return mrb_nil_value();
}

static mrb_value
rml_data_model_bind_event(mrb_state *mrb, mrb_value self)
{
  mrb_value sp; const char *name;
  mrb_get_args(mrb, "oz", &sp, &name);
  ModelSession *s = (ModelSession *)mrb_cptr(sp);
  std::string nm = name;
  mrb_state *m = s->mrb; mrb_value model = s->ruby_model;
  s->ctor->BindEventCallback(nm,
    [m, model, nm](DataModelHandle, Event &, const VariantList &) {
      mrb_funcall(m, model, "__event", 1, mrb_str_new_cstr(m, nm.c_str()));
    });
  return mrb_nil_value();
}

static mrb_value
rml_data_model_finish(mrb_state *mrb, mrb_value self)
{
  mrb_value sp;
  mrb_get_args(mrb, "o", &sp);
  ModelSession *s = (ModelSession *)mrb_cptr(sp);
  s->handle = s->ctor->GetModelHandle();
  delete s->ctor;
  s->ctor = nullptr;
  return mrb_nil_value();
}

static mrb_value
rml_data_model_dirty(mrb_state *mrb, mrb_value self)
{
  mrb_value sp; const char *name;
  mrb_get_args(mrb, "oz", &sp, &name);
  ((ModelSession *)mrb_cptr(sp))->handle.DirtyVariable(name);
  return mrb_nil_value();
}

static mrb_value
rml_data_model_dirty_all(mrb_state *mrb, mrb_value self)
{
  mrb_value sp;
  mrb_get_args(mrb, "o", &sp);
  ((ModelSession *)mrb_cptr(sp))->handle.DirtyAllVariables();
  return mrb_nil_value();
}

extern "C" void
mrb_rmlui_gem_init(mrb_state *mrb)
{
  struct RClass *rml = mrb_define_module(mrb, "Rml");

  mrb_define_module_function(mrb, rml, "_init", rml_init, MRB_ARGS_NONE());
  mrb_define_module_function(mrb, rml, "_shutdown", rml_shutdown, MRB_ARGS_NONE());
  mrb_define_module_function(mrb, rml, "_load_font", rml_load_font, MRB_ARGS_ARG(1, 1));
  mrb_define_module_function(mrb, rml, "_create_context", rml_create_context, MRB_ARGS_REQ(3));
  mrb_define_module_function(mrb, rml, "_context_set_dimensions", rml_context_set_dimensions, MRB_ARGS_REQ(3));
  mrb_define_module_function(mrb, rml, "_context_update", rml_context_update, MRB_ARGS_REQ(1));
  mrb_define_module_function(mrb, rml, "_context_render", rml_context_render, MRB_ARGS_REQ(1));
  mrb_define_module_function(mrb, rml, "_context_process_input", rml_context_process_input, MRB_ARGS_REQ(1));
  mrb_define_module_function(mrb, rml, "_context_load_document", rml_context_load_document, MRB_ARGS_REQ(2));
  mrb_define_module_function(mrb, rml, "_document_show", rml_document_show, MRB_ARGS_REQ(1));
  mrb_define_module_function(mrb, rml, "_document_hide", rml_document_hide, MRB_ARGS_REQ(1));

  mrb_define_module_function(mrb, rml, "_data_model_create", rml_data_model_create, MRB_ARGS_REQ(3));
  mrb_define_module_function(mrb, rml, "_data_model_bind_get", rml_data_model_bind_get, MRB_ARGS_REQ(2));
  mrb_define_module_function(mrb, rml, "_data_model_bind_scalar", rml_data_model_bind_scalar, MRB_ARGS_REQ(2));
  mrb_define_module_function(mrb, rml, "_data_model_bind_event", rml_data_model_bind_event, MRB_ARGS_REQ(2));
  mrb_define_module_function(mrb, rml, "_data_model_finish", rml_data_model_finish, MRB_ARGS_REQ(1));
  mrb_define_module_function(mrb, rml, "_data_model_dirty", rml_data_model_dirty, MRB_ARGS_REQ(2));
  mrb_define_module_function(mrb, rml, "_data_model_dirty_all", rml_data_model_dirty_all, MRB_ARGS_REQ(1));

  /* Element */
  mrb_define_module_function(mrb, rml, "_el_get_attribute", rml_el_get_attribute, MRB_ARGS_REQ(2));
  mrb_define_module_function(mrb, rml, "_el_set_attribute", rml_el_set_attribute, MRB_ARGS_REQ(3));
  mrb_define_module_function(mrb, rml, "_el_has_attribute", rml_el_has_attribute, MRB_ARGS_REQ(2));
  mrb_define_module_function(mrb, rml, "_el_remove_attribute", rml_el_remove_attribute, MRB_ARGS_REQ(2));
  mrb_define_module_function(mrb, rml, "_el_get_id", rml_el_get_id, MRB_ARGS_REQ(1));
  mrb_define_module_function(mrb, rml, "_el_set_id", rml_el_set_id, MRB_ARGS_REQ(2));
  mrb_define_module_function(mrb, rml, "_el_tag", rml_el_tag, MRB_ARGS_REQ(1));
  mrb_define_module_function(mrb, rml, "_el_get_inner_rml", rml_el_get_inner_rml, MRB_ARGS_REQ(1));
  mrb_define_module_function(mrb, rml, "_el_set_inner_rml", rml_el_set_inner_rml, MRB_ARGS_REQ(2));
  mrb_define_module_function(mrb, rml, "_el_set_class", rml_el_set_class, MRB_ARGS_REQ(3));
  mrb_define_module_function(mrb, rml, "_el_is_class_set", rml_el_is_class_set, MRB_ARGS_REQ(2));
  mrb_define_module_function(mrb, rml, "_el_set_property", rml_el_set_property, MRB_ARGS_REQ(3));
  mrb_define_module_function(mrb, rml, "_el_get_property", rml_el_get_property, MRB_ARGS_REQ(2));
  mrb_define_module_function(mrb, rml, "_el_remove_property", rml_el_remove_property, MRB_ARGS_REQ(2));
  mrb_define_module_function(mrb, rml, "_el_focus", rml_el_focus, MRB_ARGS_REQ(1));
  mrb_define_module_function(mrb, rml, "_el_blur", rml_el_blur, MRB_ARGS_REQ(1));
  mrb_define_module_function(mrb, rml, "_el_click", rml_el_click, MRB_ARGS_REQ(1));
  mrb_define_module_function(mrb, rml, "_el_scroll_into_view", rml_el_scroll_into_view, MRB_ARGS_ARG(1, 1));
  mrb_define_module_function(mrb, rml, "_el_select", rml_el_select, MRB_ARGS_REQ(1));
  mrb_define_module_function(mrb, rml, "_el_set_selection_range", rml_el_set_selection_range, MRB_ARGS_REQ(3));
  mrb_define_module_function(mrb, rml, "_el_is_visible", rml_el_is_visible, MRB_ARGS_REQ(1));
  mrb_define_module_function(mrb, rml, "_el_get_element_by_id", rml_el_get_element_by_id, MRB_ARGS_REQ(2));
  mrb_define_module_function(mrb, rml, "_el_query_selector", rml_el_query_selector, MRB_ARGS_REQ(2));
  mrb_define_module_function(mrb, rml, "_el_query_selector_all", rml_el_query_selector_all, MRB_ARGS_REQ(2));
  mrb_define_module_function(mrb, rml, "_el_get_elements_by_tag", rml_el_get_elements_by_tag, MRB_ARGS_REQ(2));
  mrb_define_module_function(mrb, rml, "_el_parent", rml_el_parent, MRB_ARGS_REQ(1));
  mrb_define_module_function(mrb, rml, "_el_num_children", rml_el_num_children, MRB_ARGS_REQ(1));
  mrb_define_module_function(mrb, rml, "_el_child", rml_el_child, MRB_ARGS_REQ(2));
  mrb_define_module_function(mrb, rml, "_el_owner_document", rml_el_owner_document, MRB_ARGS_REQ(1));
  mrb_define_module_function(mrb, rml, "_el_client_width", rml_el_client_width, MRB_ARGS_REQ(1));
  mrb_define_module_function(mrb, rml, "_el_client_height", rml_el_client_height, MRB_ARGS_REQ(1));
  mrb_define_module_function(mrb, rml, "_el_offset_left", rml_el_offset_left, MRB_ARGS_REQ(1));
  mrb_define_module_function(mrb, rml, "_el_offset_top", rml_el_offset_top, MRB_ARGS_REQ(1));
  mrb_define_module_function(mrb, rml, "_el_absolute_left", rml_el_absolute_left, MRB_ARGS_REQ(1));
  mrb_define_module_function(mrb, rml, "_el_absolute_top", rml_el_absolute_top, MRB_ARGS_REQ(1));
  mrb_define_module_function(mrb, rml, "_el_add_event_listener", rml_el_add_event_listener, MRB_ARGS_REQ(2) | MRB_ARGS_BLOCK());

  /* Event */
  mrb_define_module_function(mrb, rml, "_ev_type", rml_ev_type, MRB_ARGS_REQ(1));
  mrb_define_module_function(mrb, rml, "_ev_target", rml_ev_target, MRB_ARGS_REQ(1));
  mrb_define_module_function(mrb, rml, "_ev_current", rml_ev_current, MRB_ARGS_REQ(1));
  mrb_define_module_function(mrb, rml, "_ev_stop_propagation", rml_ev_stop_propagation, MRB_ARGS_REQ(1));
  mrb_define_module_function(mrb, rml, "_ev_stop_immediate", rml_ev_stop_immediate, MRB_ARGS_REQ(1));
  mrb_define_module_function(mrb, rml, "_ev_param_float", rml_ev_param_float, MRB_ARGS_REQ(2));
  mrb_define_module_function(mrb, rml, "_ev_param_str", rml_ev_param_str, MRB_ARGS_REQ(2));

  /* Document */
  mrb_define_module_function(mrb, rml, "_doc_title", rml_doc_title, MRB_ARGS_REQ(1));
  mrb_define_module_function(mrb, rml, "_doc_set_title", rml_doc_set_title, MRB_ARGS_REQ(2));
  mrb_define_module_function(mrb, rml, "_doc_pull_to_front", rml_doc_pull_to_front, MRB_ARGS_REQ(1));
  mrb_define_module_function(mrb, rml, "_doc_push_to_back", rml_doc_push_to_back, MRB_ARGS_REQ(1));
  mrb_define_module_function(mrb, rml, "_doc_close", rml_doc_close, MRB_ARGS_REQ(1));

  /* Context */
  mrb_define_module_function(mrb, rml, "_context_get_document", rml_context_get_document, MRB_ARGS_REQ(2));
  mrb_define_module_function(mrb, rml, "_context_num_documents", rml_context_num_documents, MRB_ARGS_REQ(1));
}

extern "C" void
mrb_rmlui_gem_final(mrb_state *mrb)
{
  /* RmlUi shutdown is explicit via Rml._shutdown */
}

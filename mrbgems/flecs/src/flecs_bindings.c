/* mruby bindings for flecs (ECS).
 *
 * Design mirrors flecs-lua: components are real C structs declared at runtime
 * via the meta/reflection addon (`world.struct("Position","{float x; float y;}")`),
 * and values are (de)serialized between the C memory and Ruby Hashes using the
 * PUBLIC meta API (ecs_meta_cursor for writes; EcsStruct/EcsPrimitive reflection
 * for reads) — no dependency on flecs' semi-private serialized-ops.
 *
 * Entities/components/tags are plain integer ids on the C side; the Ruby layer
 * (mrblib/flecs.rb) wraps them in Flecs::Entity / Flecs::Component. This file
 * exposes the low-level Flecs::World#_* primitives the Ruby layer builds on.
 */
#include <mruby.h>
#include <mruby/class.h>
#include <mruby/data.h>
#include <mruby/hash.h>
#include <mruby/array.h>
#include <mruby/string.h>
#include <mruby/variable.h>
#include <string.h>
#include "flecs.h"

/* ------------------------------------------------------------------ world -- */
static void fl_world_free(mrb_state *mrb, void *p) {
  if (p) ecs_fini((ecs_world_t *)p);
}
static const mrb_data_type fl_world_type = { "Flecs::World", fl_world_free };

static ecs_world_t *fl_world(mrb_state *mrb, mrb_value self) {
  ecs_world_t *w = (ecs_world_t *)mrb_data_get_ptr(mrb, self, &fl_world_type);
  if (!w) mrb_raise(mrb, E_RUNTIME_ERROR, "flecs world is not initialized");
  return w;
}

static mrb_value fl_world_init(mrb_state *mrb, mrb_value self) {
  ecs_world_t *w = ecs_init();
  mrb_data_init(self, w, &fl_world_type);
  return self;
}

/* --------------------------------------------------------------- entities -- */
/* optional string name arg -> entity id (Integer) */
static mrb_value fl_w_entity(mrb_state *mrb, mrb_value self) {
  const char *name = NULL;
  mrb_get_args(mrb, "|z!", &name);
  ecs_entity_t e = ecs_entity_init(fl_world(mrb, self),
      &(ecs_entity_desc_t){ .name = name });
  return mrb_int_value(mrb, (mrb_int)e);
}

static mrb_value fl_w_lookup(mrb_state *mrb, mrb_value self) {
  const char *name; mrb_get_args(mrb, "z", &name);
  ecs_entity_t e = ecs_lookup(fl_world(mrb, self), name);
  return e ? mrb_int_value(mrb, (mrb_int)e) : mrb_nil_value();
}

static mrb_value fl_w_name(mrb_state *mrb, mrb_value self) {
  mrb_int e; mrb_get_args(mrb, "i", &e);
  const char *n = ecs_get_name(fl_world(mrb, self), (ecs_entity_t)e);
  return n ? mrb_str_new_cstr(mrb, n) : mrb_nil_value();
}

static mrb_value fl_w_set_name(mrb_state *mrb, mrb_value self) {
  mrb_int e; const char *n; mrb_get_args(mrb, "iz", &e, &n);
  ecs_set_name(fl_world(mrb, self), (ecs_entity_t)e, n);
  return mrb_nil_value();
}

static mrb_value fl_w_delete(mrb_state *mrb, mrb_value self) {
  mrb_int e; mrb_get_args(mrb, "i", &e);
  ecs_delete(fl_world(mrb, self), (ecs_entity_t)e);
  return mrb_nil_value();
}

static mrb_value fl_w_alive(mrb_state *mrb, mrb_value self) {
  mrb_int e; mrb_get_args(mrb, "i", &e);
  return mrb_bool_value(ecs_is_alive(fl_world(mrb, self), (ecs_entity_t)e));
}

static mrb_value fl_w_add(mrb_state *mrb, mrb_value self) {
  mrb_int e, id; mrb_get_args(mrb, "ii", &e, &id);
  ecs_add_id(fl_world(mrb, self), (ecs_entity_t)e, (ecs_id_t)id);
  return mrb_nil_value();
}
static mrb_value fl_w_remove(mrb_state *mrb, mrb_value self) {
  mrb_int e, id; mrb_get_args(mrb, "ii", &e, &id);
  ecs_remove_id(fl_world(mrb, self), (ecs_entity_t)e, (ecs_id_t)id);
  return mrb_nil_value();
}
static mrb_value fl_w_has(mrb_state *mrb, mrb_value self) {
  mrb_int e, id; mrb_get_args(mrb, "ii", &e, &id);
  return mrb_bool_value(ecs_has_id(fl_world(mrb, self), (ecs_entity_t)e, (ecs_id_t)id));
}

/* --------------------------------------------------------------- meta i/o -- */
/* key (Symbol or String) -> C string */
static const char *fl_key_cstr(mrb_state *mrb, mrb_value k) {
  if (mrb_symbol_p(k)) return mrb_sym_name(mrb, mrb_symbol(k));
  if (mrb_string_p(k)) return mrb_string_value_cstr(mrb, &k);
  mrb_raise(mrb, E_TYPE_ERROR, "component field key must be a Symbol or String");
  return NULL;
}

/* write one Ruby value into the cursor's current member */
static void fl_cursor_set(mrb_state *mrb, ecs_meta_cursor_t *c, mrb_value v);

/* write a Ruby Hash into a struct scope (cursor positioned at the struct) */
static void fl_cursor_set_hash(mrb_state *mrb, ecs_meta_cursor_t *c, mrb_value hash) {
  ecs_meta_push(c);
  mrb_value keys = mrb_hash_keys(mrb, hash);
  mrb_int n = RARRAY_LEN(keys);
  for (mrb_int i = 0; i < n; i++) {
    mrb_value k = mrb_ary_ref(mrb, keys, i);
    if (ecs_meta_member(c, fl_key_cstr(mrb, k)) != 0)
      mrb_raisef(mrb, E_ARGUMENT_ERROR, "no such component field: %S", k);
    fl_cursor_set(mrb, c, mrb_hash_get(mrb, hash, k));
  }
  ecs_meta_pop(c);
}

static void fl_cursor_set(mrb_state *mrb, ecs_meta_cursor_t *c, mrb_value v) {
  switch (mrb_type(v)) {
    case MRB_TT_FLOAT:   ecs_meta_set_float(c, mrb_float(v)); break;
    case MRB_TT_INTEGER: ecs_meta_set_int(c, mrb_integer(v)); break;
    case MRB_TT_TRUE:    ecs_meta_set_bool(c, true);  break;
    case MRB_TT_FALSE:   ecs_meta_set_bool(c, false); break;
    case MRB_TT_STRING:  ecs_meta_set_string(c, mrb_string_value_cstr(mrb, &v)); break;
    case MRB_TT_HASH:    fl_cursor_set_hash(mrb, c, v); break;
    default:
      mrb_raise(mrb, E_TYPE_ERROR, "unsupported component field value type");
  }
}

/* read a struct's memory into a Ruby Hash (direct offset reads, public reflection) */
static mrb_value fl_read_struct(mrb_state *mrb, ecs_world_t *w,
                                ecs_entity_t type, const void *base) {
  const EcsStruct *st = ecs_get(w, type, EcsStruct);
  if (!st) return mrb_nil_value();
  mrb_value hash = mrb_hash_new(mrb);
  ecs_member_t *m = ecs_vec_first(&st->members);
  int32_t count = ecs_vec_count(&st->members);
  for (int32_t i = 0; i < count; i++) {
    const void *mp = (const char *)base + m[i].offset;
    mrb_value key = mrb_symbol_value(mrb_intern_cstr(mrb, m[i].name));
    mrb_value val;
    const EcsPrimitive *prim = ecs_get(w, m[i].type, EcsPrimitive);
    if (prim) {
      switch (prim->kind) {
        case EcsBool:   val = mrb_bool_value(*(const bool *)mp); break;
        case EcsChar:   val = mrb_int_value(mrb, *(const char *)mp); break;
        case EcsByte:
        case EcsU8:     val = mrb_int_value(mrb, *(const uint8_t *)mp); break;
        case EcsU16:    val = mrb_int_value(mrb, *(const uint16_t *)mp); break;
        case EcsU32:    val = mrb_int_value(mrb, *(const uint32_t *)mp); break;
        case EcsU64:    val = mrb_int_value(mrb, (mrb_int)*(const uint64_t *)mp); break;
        case EcsI8:     val = mrb_int_value(mrb, *(const int8_t *)mp); break;
        case EcsI16:    val = mrb_int_value(mrb, *(const int16_t *)mp); break;
        case EcsI32:    val = mrb_int_value(mrb, *(const int32_t *)mp); break;
        case EcsI64:    val = mrb_int_value(mrb, (mrb_int)*(const int64_t *)mp); break;
        case EcsF32:    val = mrb_float_value(mrb, *(const float *)mp); break;
        case EcsF64:    val = mrb_float_value(mrb, *(const double *)mp); break;
        case EcsUPtr:   val = mrb_int_value(mrb, (mrb_int)*(const uintptr_t *)mp); break;
        case EcsIPtr:   val = mrb_int_value(mrb, (mrb_int)*(const intptr_t *)mp); break;
        case EcsEntity:
        case EcsId:     val = mrb_int_value(mrb, (mrb_int)*(const ecs_entity_t *)mp); break;
        case EcsString: {
          const char *s = *(const char *const *)mp;
          val = s ? mrb_str_new_cstr(mrb, s) : mrb_nil_value();
          break;
        }
        default: val = mrb_nil_value();
      }
    } else if (ecs_get(w, m[i].type, EcsStruct)) {
      val = fl_read_struct(mrb, w, m[i].type, mp); /* nested struct */
    } else {
      val = mrb_int_value(mrb, *(const int32_t *)mp); /* enum/bitmask fallback */
    }
    mrb_hash_set(mrb, hash, key, val);
  }
  return hash;
}

/* world._set(entity, comp, hash) */
static mrb_value fl_w_set(mrb_state *mrb, mrb_value self) {
  mrb_int e, comp; mrb_value hash;
  mrb_get_args(mrb, "iiH", &e, &comp, &hash);
  ecs_world_t *w = fl_world(mrb, self);
  const EcsComponent *ci = ecs_get(w, (ecs_entity_t)comp, EcsComponent);
  if (!ci) mrb_raise(mrb, E_ARGUMENT_ERROR, "not a component (a tag has no data to set)");
  void *ptr = ecs_ensure_id(w, (ecs_entity_t)e, (ecs_id_t)comp, (size_t)ci->size);
  if (!ptr) mrb_raise(mrb, E_RUNTIME_ERROR, "ecs_ensure_id failed");
  ecs_meta_cursor_t c = ecs_meta_cursor(w, (ecs_entity_t)comp, ptr);
  fl_cursor_set_hash(mrb, &c, hash);
  ecs_modified_id(w, (ecs_entity_t)e, (ecs_id_t)comp);
  return self;
}

/* world._get(entity, comp) -> hash | nil */
static mrb_value fl_w_get(mrb_state *mrb, mrb_value self) {
  mrb_int e, comp; mrb_get_args(mrb, "ii", &e, &comp);
  ecs_world_t *w = fl_world(mrb, self);
  const void *ptr = ecs_get_id(w, (ecs_entity_t)e, (ecs_id_t)comp);
  if (!ptr) return mrb_nil_value();
  return fl_read_struct(mrb, w, (ecs_entity_t)comp, ptr);
}

/* ------------------------------------------------------------ components --- */
/* world._struct(name, descriptor) -> component id */
static mrb_value fl_w_struct(mrb_state *mrb, mrb_value self) {
  const char *name, *desc;
  mrb_get_args(mrb, "zz", &name, &desc);
  ecs_world_t *w = fl_world(mrb, self);
  ecs_entity_t c = ecs_entity_init(w, &(ecs_entity_desc_t){ .name = name });
  if (ecs_meta_from_desc(w, c, EcsStructType, desc) != 0)
    mrb_raisef(mrb, E_ARGUMENT_ERROR, "invalid struct descriptor for %S",
               mrb_str_new_cstr(mrb, name));
  return mrb_int_value(mrb, (mrb_int)c);
}

/* ----------------------------------------------------------- query/system -- */
typedef struct { mrb_state *mrb; mrb_value blk; } fl_cb_t;

static void fl_cb_free(void *ctx) {
  fl_cb_t *cb = ctx;
  if (cb) { mrb_gc_unregister(cb->mrb, cb->blk); ecs_os_free(cb); }
}

/* shared: run a Ruby block over an iterator, yielding (entity, *comp_hashes)
 * and writing any mutated hashes back into component memory each row. */
static void fl_yield_iter(mrb_state *mrb, mrb_value blk, ecs_iter_t *it) {
  ecs_world_t *w = it->world;
  int8_t fields = it->field_count;
  for (int32_t row = 0; row < it->count; row++) {
    mrb_value argv[1 + 16];
    int argc = 0;
    argv[argc++] = mrb_int_value(mrb, (mrb_int)it->entities[row]);
    void *ptrs[16];
    ecs_entity_t types[16];
    int nf = fields < 16 ? fields : 16;
    for (int8_t f = 0; f < nf; f++) {
      ecs_entity_t type = ecs_get_typeid(w, ecs_field_id(it, f));
      size_t size = ecs_field_size(it, f);
      void *col = ecs_field_w_size(it, size, f);
      void *cell = col ? (char *)col + size * row : NULL;
      ptrs[f] = cell; types[f] = type;
      argv[argc++] = (cell && ecs_has(w, type, EcsStruct))
        ? fl_read_struct(mrb, w, type, cell) : mrb_nil_value();
    }
    mrb_value r = mrb_yield_argv(mrb, blk, argc, argv);
    (void)r;
    /* write back any hash args (mutations persist) */
    for (int8_t f = 0; f < nf; f++) {
      if (!ptrs[f]) continue;
      mrb_value hv = argv[1 + f];
      if (mrb_hash_p(hv)) {
        ecs_meta_cursor_t c = ecs_meta_cursor(w, types[f], ptrs[f]);
        fl_cursor_set_hash(mrb, &c, hv);
      }
    }
  }
}

/* build an ecs_query_desc_t from a Ruby Array of component ids */
static void fl_fill_terms(mrb_state *mrb, mrb_value ids, ecs_query_desc_t *qd) {
  mrb_int n = RARRAY_LEN(ids);
  if (n > FLECS_TERM_COUNT_MAX)
    mrb_raise(mrb, E_ARGUMENT_ERROR, "too many query terms");
  for (mrb_int i = 0; i < n; i++)
    qd->terms[i].id = (ecs_id_t)mrb_as_int(mrb, mrb_ary_ref(mrb, ids, i));
}

/* --- cached query --- */
static void fl_query_free(mrb_state *mrb, void *p) {
  if (p) ecs_query_fini((ecs_query_t *)p);
}
static const mrb_data_type fl_query_type = { "Flecs::Query", fl_query_free };

/* world._query(ids_array) -> Flecs::Query */
static mrb_value fl_w_query(mrb_state *mrb, mrb_value self) {
  mrb_value ids; mrb_get_args(mrb, "A", &ids);
  ecs_world_t *w = fl_world(mrb, self);
  ecs_query_desc_t qd = (ecs_query_desc_t){0};
  fl_fill_terms(mrb, ids, &qd);
  ecs_query_t *q = ecs_query_init(w, &qd);
  if (!q) mrb_raise(mrb, E_ARGUMENT_ERROR, "failed to create query");
  struct RClass *m = mrb_module_get(mrb, "Flecs");
  struct RClass *cls = mrb_class_get_under(mrb, m, "Query");
  mrb_value obj = mrb_obj_value(mrb_data_object_alloc(mrb, cls, q, &fl_query_type));
  mrb_iv_set(mrb, obj, mrb_intern_lit(mrb, "@world"), self);
  return obj;
}

/* query._each { |e, *comps| } */
static mrb_value fl_q_each(mrb_state *mrb, mrb_value self) {
  mrb_value blk; mrb_get_args(mrb, "&", &blk);
  if (mrb_nil_p(blk)) mrb_raise(mrb, E_ARGUMENT_ERROR, "block required");
  ecs_query_t *q = (ecs_query_t *)mrb_data_get_ptr(mrb, self, &fl_query_type);
  mrb_value wv = mrb_iv_get(mrb, self, mrb_intern_lit(mrb, "@world"));
  ecs_world_t *w = fl_world(mrb, wv);
  ecs_iter_t it = ecs_query_iter(w, q);
  while (ecs_query_next(&it)) fl_yield_iter(mrb, blk, &it);
  return self;
}

/* --- system --- */
static void fl_system_cb(ecs_iter_t *it) {
  fl_cb_t *cb = it->callback_ctx;
  if (cb) fl_yield_iter(cb->mrb, cb->blk, it);
}

/* world._system(name, phase, ids_array, &blk) -> system id */
static mrb_value fl_w_system(mrb_state *mrb, mrb_value self) {
  const char *name; mrb_int phase; mrb_value ids, blk;
  mrb_get_args(mrb, "ziA&", &name, &phase, &ids, &blk);
  if (mrb_nil_p(blk)) mrb_raise(mrb, E_ARGUMENT_ERROR, "system requires a block");
  ecs_world_t *w = fl_world(mrb, self);

  fl_cb_t *cb = ecs_os_malloc(sizeof(fl_cb_t));
  cb->mrb = mrb; cb->blk = blk;
  mrb_gc_register(mrb, blk); /* keep the block alive for the world's lifetime */

  ecs_entity_t phase_e = (ecs_entity_t)phase;
  ecs_id_t add_ids[] = { phase_e ? ecs_dependson(phase_e) : 0, phase_e, 0 };
  ecs_entity_t se = ecs_entity_init(w, &(ecs_entity_desc_t){
    .name = name,
    .add = add_ids,
  });
  ecs_system_desc_t sd = (ecs_system_desc_t){0};
  sd.entity = se;
  fl_fill_terms(mrb, ids, &sd.query);
  sd.callback = fl_system_cb;
  sd.callback_ctx = cb;
  sd.callback_ctx_free = fl_cb_free;
  ecs_entity_t s = ecs_system_init(w, &sd);
  return mrb_int_value(mrb, (mrb_int)s);
}

/* world._progress(dt) -> bool (false when world should quit) */
static mrb_value fl_w_progress(mrb_state *mrb, mrb_value self) {
  mrb_float dt = 0; mrb_get_args(mrb, "|f", &dt);
  return mrb_bool_value(ecs_progress(fl_world(mrb, self), (ecs_ftime_t)dt));
}

/* --- observability (R5): flecs REST API + stats, for the hosted Explorer ---- */
/* In-process REST server handle (set by _enable_rest). Used by _rest_request so
 * bin/snapshot / bin/query get JSON without a socket — works on desktop AND web
 * (ecs_http_server_request processes the request handler directly). */
static ecs_http_server_t *fl_rest_server = NULL;

/* world._enable_rest(port=27750) -> self. Starts the REST HTTP server (served
 * during progress); connect the hosted Flecs Explorer remotely. Dev-only. */
static mrb_value fl_w_enable_rest(mrb_state *mrb, mrb_value self) {
  mrb_int port = ECS_REST_DEFAULT_PORT;
  mrb_get_args(mrb, "|i", &port);
  ecs_world_t *w = fl_world(mrb, self);
  /* In-process REST handle for bin/snapshot / bin/query (both targets). */
  fl_rest_server = ecs_rest_server_init(w, NULL);
#ifdef __EMSCRIPTEN__
  /* No listening sockets in the browser (R5a). flecs serves REST from the wasm
   * image via flecs_explorer_request() over this socketless server. */
  (void)port;
  extern ecs_http_server_t *flecs_wasm_rest_server;
  flecs_wasm_rest_server = fl_rest_server;
#else
  /* Desktop: also start the HTTP listener for the hosted Flecs Explorer.
   * (This creates a second server object with a port; both share the world.) */
  FlecsRestImport(w);
  ecs_set(w, EcsWorld, EcsRest, {.port = (uint16_t)port});
#endif
  return self;
}

/* world._rest_request(method, path, body="") -> String|nil (JSON from flecs REST).
 * Requires _enable_rest first. In-process (no socket) — works on both targets. */
static mrb_value fl_w_rest_request(mrb_state *mrb, mrb_value self) {
  const char *method, *path; const char *body = "";
  mrb_get_args(mrb, "zz|z", &method, &path, &body);
  if (!fl_rest_server)
    mrb_raise(mrb, E_RUNTIME_ERROR,
              "REST server not initialized (call enable_rest first)");
  ecs_http_reply_t reply = ECS_HTTP_REPLY_INIT;
  ecs_http_server_request(fl_rest_server, method, path, body, &reply);
  char *json = ecs_strbuf_get(&reply.body);
  mrb_value result = json ? mrb_str_new_cstr(mrb, json) : mrb_nil_value();
  ecs_os_free(json);
  return result;
}

/* world._enable_stats -> self. Per-system timing + world monitor stats. */
static mrb_value fl_w_enable_stats(mrb_state *mrb, mrb_value self) {
  ecs_world_t *w = fl_world(mrb, self);
  FlecsStatsImport(w);
  return self;
}

/* ------------------------------------------------------------------ init --- */
void mrb_flecs_gem_init(mrb_state *mrb) {
  struct RClass *m = mrb_define_module(mrb, "Flecs");

  struct RClass *world = mrb_define_class_under(mrb, m, "World", mrb->object_class);
  MRB_SET_INSTANCE_TT(world, MRB_TT_DATA);
  mrb_define_method(mrb, world, "initialize", fl_world_init, MRB_ARGS_NONE());
  mrb_define_method(mrb, world, "_entity",   fl_w_entity,   MRB_ARGS_OPT(1));
  mrb_define_method(mrb, world, "_lookup",   fl_w_lookup,   MRB_ARGS_REQ(1));
  mrb_define_method(mrb, world, "_name",     fl_w_name,     MRB_ARGS_REQ(1));
  mrb_define_method(mrb, world, "_set_name", fl_w_set_name, MRB_ARGS_REQ(2));
  mrb_define_method(mrb, world, "_delete",   fl_w_delete,   MRB_ARGS_REQ(1));
  mrb_define_method(mrb, world, "_alive?",   fl_w_alive,    MRB_ARGS_REQ(1));
  mrb_define_method(mrb, world, "_add",      fl_w_add,      MRB_ARGS_REQ(2));
  mrb_define_method(mrb, world, "_remove",   fl_w_remove,   MRB_ARGS_REQ(2));
  mrb_define_method(mrb, world, "_has?",     fl_w_has,      MRB_ARGS_REQ(2));
  mrb_define_method(mrb, world, "_set",      fl_w_set,      MRB_ARGS_REQ(3));
  mrb_define_method(mrb, world, "_get",      fl_w_get,      MRB_ARGS_REQ(2));
  mrb_define_method(mrb, world, "_struct",   fl_w_struct,   MRB_ARGS_REQ(2));
  mrb_define_method(mrb, world, "_query",    fl_w_query,    MRB_ARGS_REQ(1));
  mrb_define_method(mrb, world, "_system",   fl_w_system,   MRB_ARGS_REQ(3) | MRB_ARGS_BLOCK());
  mrb_define_method(mrb, world, "_progress", fl_w_progress, MRB_ARGS_OPT(1));
  mrb_define_method(mrb, world, "_enable_rest",  fl_w_enable_rest,  MRB_ARGS_OPT(1));
  mrb_define_method(mrb, world, "_rest_request", fl_w_rest_request, MRB_ARGS_ARG(2, 1));
  mrb_define_method(mrb, world, "_enable_stats", fl_w_enable_stats, MRB_ARGS_NONE());

  struct RClass *query = mrb_define_class_under(mrb, m, "Query", mrb->object_class);
  MRB_SET_INSTANCE_TT(query, MRB_TT_DATA);
  mrb_define_method(mrb, query, "_each", fl_q_each, MRB_ARGS_BLOCK());

  /* pipeline phase ids (constants on Flecs) */
  mrb_define_const(mrb, m, "ON_LOAD",    mrb_int_value(mrb, (mrb_int)EcsOnLoad));
  mrb_define_const(mrb, m, "PRE_UPDATE", mrb_int_value(mrb, (mrb_int)EcsPreUpdate));
  mrb_define_const(mrb, m, "ON_UPDATE",  mrb_int_value(mrb, (mrb_int)EcsOnUpdate));
  mrb_define_const(mrb, m, "ON_START",   mrb_int_value(mrb, (mrb_int)EcsOnStart));
}

void mrb_flecs_gem_final(mrb_state *mrb) { (void)mrb; }

/* mruby bindings for Jolt Physics (3D) via the joltc C API.
 *
 * Exposes low-level Jolt::World#_* primitives + Jolt._box/_sphere/... shape
 * factories. The Ruby layer (mrblib/jolt.rb) wraps these in a friendly API and
 * converts to/from Rl::Vector3 / arrays.
 *
 * Single-threaded by design: the job system is created with numThreads=0 so jobs
 * run inline on the calling thread — the only mode valid on the wasm/web build,
 * and identical behaviour on desktop.
 *
 * Layers: a fixed 2-layer setup — 0 = STATIC (non-moving), 1 = MOVING. A body's
 * layer is derived from its motion type (static -> STATIC, else MOVING).
 */
#include <mruby.h>
#include <mruby/class.h>
#include <mruby/data.h>
#include <mruby/array.h>
#include <mruby/string.h>
#include <mruby/variable.h>
#include <stdbool.h>
#include <stdlib.h>
#include <math.h>
#include "joltc.h"

enum { L_STATIC = 0, L_MOVING = 1, L_NUM = 2 };

/* Shared "world is alive" token. mruby's mrb_close frees every object in an
 * arbitrary order, ignoring references — so a Ragdoll/Constraint finalizer can
 * run AFTER its World's JPH_PhysicsSystem is already destroyed, and calling
 * RemoveFromPhysicsSystem/RemoveConstraint on a freed system segfaults. The
 * world and each dependent share this refcounted token; the world clears `alive`
 * when destroyed, and dependents skip system access once it's dead. Last owner
 * frees it. Uses libc malloc/free (independent of the mruby heap). */
typedef struct { int alive; int refs; } jolt_token_t;
static jolt_token_t *jolt_token_new(void) {
  jolt_token_t *t = (jolt_token_t *)malloc(sizeof(jolt_token_t));
  if (t) { t->alive = 1; t->refs = 1; }
  return t;
}
static jolt_token_t *jolt_token_acquire(jolt_token_t *t) { if (t) t->refs++; return t; }
static void jolt_token_release(jolt_token_t *t) { if (t && --t->refs == 0) free(t); }

/* one "contact added" event collected during a step */
typedef struct { uint64_t a, b; float px, py, pz, nx, ny, nz; } jolt_contact_t;
/* one "contact removed" (stopped touching) event */
typedef struct { uint64_t a, b; } jolt_pair_t;

/* a unit vector perpendicular to `a` (for hinge/slider normal axis) */
static JPH_Vec3 jolt_perp(JPH_Vec3 a) {
  JPH_Vec3 r;
  if (fabsf(a.x) <= fabsf(a.y) && fabsf(a.x) <= fabsf(a.z)) r = (JPH_Vec3){ 1, 0, 0 };
  else if (fabsf(a.y) <= fabsf(a.z))                        r = (JPH_Vec3){ 0, 1, 0 };
  else                                                      r = (JPH_Vec3){ 0, 0, 1 };
  JPH_Vec3 c = { a.y*r.z - a.z*r.y, a.z*r.x - a.x*r.z, a.x*r.y - a.y*r.x };
  float L = sqrtf(c.x*c.x + c.y*c.y + c.z*c.z);
  if (L > 1e-6f) { c.x/=L; c.y/=L; c.z/=L; }
  return c;
}

/* ------------------------------------------------------------------ world -- */
typedef struct {
  JPH_PhysicsSystem   *sys;
  JPH_BodyInterface   *bi;
  JPH_JobSystem       *jobs;
  JPH_ContactListener *listener;
  jolt_contact_t      *contacts;     /* new contacts this step */
  int                  contact_count;
  int                  contact_cap;
  jolt_pair_t         *ended;        /* contacts removed this step */
  int                  ended_count;
  int                  ended_cap;
  jolt_token_t        *token;        /* shared liveness, see jolt_token_t */
} jolt_world_t;

static void jolt_world_free(mrb_state *mrb, void *p) {
  jolt_world_t *w = p;
  if (w) {
    if (w->token) w->token->alive = 0;   /* tell dependents the system is gone */
    if (w->sys)      JPH_PhysicsSystem_Destroy(w->sys);
    if (w->listener) JPH_ContactListener_Destroy(w->listener);
    if (w->jobs)     JPH_JobSystem_Destroy(w->jobs);
    if (w->contacts) mrb_free(mrb, w->contacts);
    if (w->ended)    mrb_free(mrb, w->ended);
    jolt_token_release(w->token);
    mrb_free(mrb, w);
  }
}

/* stable JPH_Body* for a body id (single-threaded: lock is a no-op, the pointer
 * is stable because bodies don't move in memory). Needed for constraints and
 * raycast surface normals, which take JPH_Body* rather than an id. */
static JPH_Body *jolt_body_for(jolt_world_t *w, JPH_BodyID id) {
  const JPH_BodyLockInterface *li = JPH_PhysicsSystem_GetBodyLockInterfaceNoLock(w->sys);
  JPH_BodyLockRead lock;
  JPH_BodyLockInterface_LockRead(li, id, &lock);
  JPH_Body *b = (JPH_Body *)lock.body;
  JPH_BodyLockInterface_UnlockRead(li, &lock);
  return b;
}

/* contact listener: global procs (shared by all worlds); each listener carries
 * its world as userData so we can route the event to the right contact buffer.
 * Runs inline during Update (single-threaded), so writing the buffer is safe. */
static void JPH_API_CALL jolt_on_contact_added(
    void *ud, const JPH_Body *b1, const JPH_Body *b2,
    const JPH_ContactManifold *m, JPH_ContactSettings *settings) {
  (void)settings;
  jolt_world_t *w = (jolt_world_t *)ud;
  if (!w || w->contact_count >= w->contact_cap) return;
  jolt_contact_t *c = &w->contacts[w->contact_count++];
  c->a = JPH_Body_GetID(b1);
  c->b = JPH_Body_GetID(b2);
  JPH_Vec3 n; JPH_ContactManifold_GetWorldSpaceNormal(m, &n);
  c->nx = n.x; c->ny = n.y; c->nz = n.z;
  c->px = c->py = c->pz = 0;
  if (JPH_ContactManifold_GetPointCount(m) > 0) {
    JPH_RVec3 p; JPH_ContactManifold_GetWorldSpaceContactPointOn1(m, 0, &p);
    c->px = p.x; c->py = p.y; c->pz = p.z;
  }
}
static void JPH_API_CALL jolt_on_contact_removed(void *ud, const JPH_SubShapeIDPair *pair) {
  jolt_world_t *w = (jolt_world_t *)ud;
  if (!w || w->ended_count >= w->ended_cap) return;
  jolt_pair_t *e = &w->ended[w->ended_count++];
  e->a = pair->Body1ID; e->b = pair->Body2ID;
}
static JPH_ContactListener_Procs g_contact_procs;
static const mrb_data_type jolt_world_type = { "Jolt::World", jolt_world_free };

static jolt_world_t *jolt_world(mrb_state *mrb, mrb_value self) {
  jolt_world_t *w = mrb_data_get_ptr(mrb, self, &jolt_world_type);
  if (!w) mrb_raise(mrb, E_RUNTIME_ERROR, "Jolt world not initialized");
  return w;
}

/* _setup(gx, gy, gz, max_bodies) — called from the Ruby keyword initializer */
static mrb_value jolt_world_init(mrb_state *mrb, mrb_value self) {
  mrb_float gx, gy, gz; mrb_int max_bodies;
  mrb_get_args(mrb, "fffi", &gx, &gy, &gz, &max_bodies);

  jolt_world_t *w = mrb_malloc(mrb, sizeof(jolt_world_t));

  JobSystemThreadPoolConfig jc = { 2048, 16, 0 }; /* numThreads=0 -> inline */
  w->jobs = JPH_JobSystemThreadPool_Create(&jc);

  JPH_ObjectLayerPairFilter *opf = JPH_ObjectLayerPairFilterTable_Create(L_NUM);
  JPH_ObjectLayerPairFilterTable_EnableCollision(opf, L_STATIC, L_MOVING);
  JPH_ObjectLayerPairFilterTable_EnableCollision(opf, L_MOVING, L_STATIC);
  /* dynamic-vs-dynamic: without this, moving bodies pass through each other */
  JPH_ObjectLayerPairFilterTable_EnableCollision(opf, L_MOVING, L_MOVING);

  JPH_BroadPhaseLayerInterface *bpi = JPH_BroadPhaseLayerInterfaceTable_Create(L_NUM, L_NUM);
  JPH_BroadPhaseLayerInterfaceTable_MapObjectToBroadPhaseLayer(bpi, L_STATIC, 0);
  JPH_BroadPhaseLayerInterfaceTable_MapObjectToBroadPhaseLayer(bpi, L_MOVING, 1);

  JPH_ObjectVsBroadPhaseLayerFilter *ovb =
      JPH_ObjectVsBroadPhaseLayerFilterTable_Create(bpi, L_NUM, opf, L_NUM);

  JPH_PhysicsSystemSettings s = {0};
  s.maxBodies = (uint32_t)max_bodies;
  s.maxBodyPairs = (uint32_t)max_bodies;
  s.maxContactConstraints = (uint32_t)max_bodies;
  s.broadPhaseLayerInterface = bpi;
  s.objectLayerPairFilter = opf;
  s.objectVsBroadPhaseLayerFilter = ovb;
  w->sys = JPH_PhysicsSystem_Create(&s);
  w->bi  = JPH_PhysicsSystem_GetBodyInterface(w->sys);

  JPH_Vec3 g = { (float)gx, (float)gy, (float)gz };
  JPH_PhysicsSystem_SetGravity(w->sys, &g);

  /* contact events */
  w->contact_cap   = 4096;
  w->contact_count = 0;
  w->contacts  = mrb_malloc(mrb, sizeof(jolt_contact_t) * w->contact_cap);
  w->ended_cap   = 4096;
  w->ended_count = 0;
  w->ended     = mrb_malloc(mrb, sizeof(jolt_pair_t) * w->ended_cap);
  w->listener  = JPH_ContactListener_Create(w);
  JPH_PhysicsSystem_SetContactListener(w->sys, w->listener);
  w->token = jolt_token_new();

  mrb_data_init(self, w, &jolt_world_type);
  return self;
}

static mrb_value jolt_step(mrb_state *mrb, mrb_value self) {
  mrb_float dt; mrb_int steps;
  mrb_get_args(mrb, "fi", &dt, &steps);
  jolt_world_t *w = jolt_world(mrb, self);
  w->contact_count = 0;                       /* contacts reflect only this step */
  w->ended_count   = 0;
  JPH_PhysicsSystem_Update(w->sys, (float)dt, (int)steps, w->jobs);
  return self;
}

/* -> Array of [idA, idB] for contacts that ENDED (stopped touching) this step */
static mrb_value jolt_contacts_ended(mrb_state *mrb, mrb_value self) {
  jolt_world_t *w = jolt_world(mrb, self);
  mrb_value arr = mrb_ary_new_capa(mrb, w->ended_count);
  for (int i = 0; i < w->ended_count; i++) {
    mrb_value e = mrb_ary_new_capa(mrb, 2);
    mrb_ary_push(mrb, e, mrb_int_value(mrb, (mrb_int)w->ended[i].a));
    mrb_ary_push(mrb, e, mrb_int_value(mrb, (mrb_int)w->ended[i].b));
    mrb_ary_push(mrb, arr, e);
  }
  return arr;
}

/* -> Array of [idA, idB, px,py,pz, nx,ny,nz] for contacts begun this step */
static mrb_value jolt_contacts(mrb_state *mrb, mrb_value self) {
  jolt_world_t *w = jolt_world(mrb, self);
  mrb_value arr = mrb_ary_new_capa(mrb, w->contact_count);
  for (int i = 0; i < w->contact_count; i++) {
    jolt_contact_t *c = &w->contacts[i];
    mrb_value e = mrb_ary_new_capa(mrb, 8);
    mrb_ary_push(mrb, e, mrb_int_value(mrb, (mrb_int)c->a));
    mrb_ary_push(mrb, e, mrb_int_value(mrb, (mrb_int)c->b));
    mrb_ary_push(mrb, e, mrb_float_value(mrb, c->px));
    mrb_ary_push(mrb, e, mrb_float_value(mrb, c->py));
    mrb_ary_push(mrb, e, mrb_float_value(mrb, c->pz));
    mrb_ary_push(mrb, e, mrb_float_value(mrb, c->nx));
    mrb_ary_push(mrb, e, mrb_float_value(mrb, c->ny));
    mrb_ary_push(mrb, e, mrb_float_value(mrb, c->nz));
    mrb_ary_push(mrb, arr, e);
  }
  return arr;
}

static mrb_value jolt_optimize(mrb_state *mrb, mrb_value self) {
  JPH_PhysicsSystem_OptimizeBroadPhase(jolt_world(mrb, self)->sys);
  return self;
}

static mrb_value jolt_set_gravity(mrb_state *mrb, mrb_value self) {
  mrb_float x, y, z; mrb_get_args(mrb, "fff", &x, &y, &z);
  JPH_Vec3 g = { (float)x, (float)y, (float)z };
  JPH_PhysicsSystem_SetGravity(jolt_world(mrb, self)->sys, &g);
  return self;
}

static mrb_value vec3_ary(mrb_state *mrb, float x, float y, float z) {
  mrb_value a = mrb_ary_new_capa(mrb, 3);
  mrb_ary_push(mrb, a, mrb_float_value(mrb, x));
  mrb_ary_push(mrb, a, mrb_float_value(mrb, y));
  mrb_ary_push(mrb, a, mrb_float_value(mrb, z));
  return a;
}

/* ----------------------------------------------------------------- shapes -- */
/* Shapes are reference-counted in Jolt; the body holds a ref. We don't release
 * on GC (shapes are typically long-lived/shared) — a small, bounded leak. */
static const mrb_data_type jolt_shape_type = { "Jolt::Shape", NULL };

static mrb_value wrap_shape(mrb_state *mrb, JPH_Shape *sh) {
  struct RClass *m = mrb_module_get(mrb, "Jolt");
  struct RClass *c = mrb_class_get_under(mrb, m, "Shape");
  return mrb_obj_value(mrb_data_object_alloc(mrb, c, sh, &jolt_shape_type));
}
static JPH_Shape *shape_ptr(mrb_state *mrb, mrb_value v) {
  return mrb_data_get_ptr(mrb, v, &jolt_shape_type);
}

static mrb_value jolt_box(mrb_state *mrb, mrb_value self) {
  mrb_float hx, hy, hz; mrb_get_args(mrb, "fff", &hx, &hy, &hz);
  JPH_Vec3 he = { (float)hx, (float)hy, (float)hz };
  return wrap_shape(mrb, (JPH_Shape*)JPH_BoxShape_Create(&he, JPH_DEFAULT_CONVEX_RADIUS));
}
static mrb_value jolt_sphere(mrb_state *mrb, mrb_value self) {
  mrb_float r; mrb_get_args(mrb, "f", &r);
  return wrap_shape(mrb, (JPH_Shape*)JPH_SphereShape_Create((float)r));
}
static mrb_value jolt_capsule(mrb_state *mrb, mrb_value self) {
  mrb_float hh, r; mrb_get_args(mrb, "ff", &hh, &r);
  return wrap_shape(mrb, (JPH_Shape*)JPH_CapsuleShape_Create((float)hh, (float)r));
}
static mrb_value jolt_cylinder(mrb_state *mrb, mrb_value self) {
  mrb_float hh, r; mrb_get_args(mrb, "ff", &hh, &r);
  return wrap_shape(mrb, (JPH_Shape*)JPH_CylinderShape_Create((float)hh, (float)r));
}
/* convex hull from a flat array of points [x,y,z, x,y,z, ...] */
static mrb_value jolt_convex_hull(mrb_state *mrb, mrb_value self) {
  mrb_value pts; mrb_get_args(mrb, "A", &pts);
  mrb_int n = RARRAY_LEN(pts) / 3;
  if (n < 3) mrb_raise(mrb, E_ARGUMENT_ERROR, "convex hull needs >= 3 points");
  JPH_Vec3 *v = mrb_malloc(mrb, sizeof(JPH_Vec3) * n);
  for (mrb_int i = 0; i < n; i++) {
    v[i].x = (float)mrb_as_float(mrb, mrb_ary_ref(mrb, pts, i*3));
    v[i].y = (float)mrb_as_float(mrb, mrb_ary_ref(mrb, pts, i*3+1));
    v[i].z = (float)mrb_as_float(mrb, mrb_ary_ref(mrb, pts, i*3+2));
  }
  JPH_ConvexHullShapeSettings *st =
      JPH_ConvexHullShapeSettings_Create(v, (uint32_t)n, JPH_DEFAULT_CONVEX_RADIUS);
  JPH_Shape *sh = (JPH_Shape*)JPH_ConvexHullShapeSettings_CreateShape(st);
  mrb_free(mrb, v);
  return wrap_shape(mrb, sh);
}
/* triangle mesh (STATIC bodies only) from a flat array; 9 floats = 1 triangle */
static mrb_value jolt_mesh(mrb_state *mrb, mrb_value self) {
  mrb_value verts; mrb_get_args(mrb, "A", &verts);
  mrb_int ntri = RARRAY_LEN(verts) / 9;
  if (ntri < 1) mrb_raise(mrb, E_ARGUMENT_ERROR, "mesh needs >= 9 floats (one triangle)");
  JPH_Triangle *tris = mrb_malloc(mrb, sizeof(JPH_Triangle) * ntri);
  for (mrb_int t = 0; t < ntri; t++) {
    float f[9];
    for (int k = 0; k < 9; k++) f[k] = (float)mrb_as_float(mrb, mrb_ary_ref(mrb, verts, t*9+k));
    tris[t].v1.x=f[0]; tris[t].v1.y=f[1]; tris[t].v1.z=f[2];
    tris[t].v2.x=f[3]; tris[t].v2.y=f[4]; tris[t].v2.z=f[5];
    tris[t].v3.x=f[6]; tris[t].v3.y=f[7]; tris[t].v3.z=f[8];
    tris[t].materialIndex = 0;
  }
  JPH_MeshShapeSettings *st = JPH_MeshShapeSettings_Create(tris, (uint32_t)ntri);
  JPH_Shape *sh = (JPH_Shape*)JPH_MeshShapeSettings_CreateShape(st);
  mrb_free(mrb, tris);
  return wrap_shape(mrb, sh);
}

/* ------------------------------------------------------------------ bodies - */
/* _add_body(shape, px,py,pz, qx,qy,qz,qw, motion, restitution, friction, activate) */
static mrb_value jolt_add_body(mrb_state *mrb, mrb_value self) {
  mrb_value shape; mrb_float px,py,pz, qx,qy,qz,qw, rest, fric, lin_damp, ang_damp, mass;
  mrb_int motion; mrb_bool activate, ccd, sensor;
  mrb_get_args(mrb, "offfffffiffbfffbb", &shape, &px,&py,&pz, &qx,&qy,&qz,&qw,
               &motion, &rest, &fric, &activate, &lin_damp, &ang_damp, &mass, &ccd, &sensor);
  jolt_world_t *w = jolt_world(mrb, self);

  JPH_ObjectLayer layer = (motion == JPH_MotionType_Static) ? L_STATIC : L_MOVING;
  JPH_RVec3 pos = { (float)px, (float)py, (float)pz };
  JPH_Quat  rot = { (float)qx, (float)qy, (float)qz, (float)qw };
  JPH_BodyCreationSettings *bcs = JPH_BodyCreationSettings_Create3(
      shape_ptr(mrb, shape), &pos, &rot, (JPH_MotionType)motion, layer);
  JPH_BodyCreationSettings_SetRestitution(bcs, (float)rest);
  JPH_BodyCreationSettings_SetFriction(bcs, (float)fric);
  JPH_BodyCreationSettings_SetLinearDamping(bcs, (float)lin_damp);
  JPH_BodyCreationSettings_SetAngularDamping(bcs, (float)ang_damp);
  JPH_BodyCreationSettings_SetIsSensor(bcs, sensor);
  JPH_BodyCreationSettings_SetMotionQuality(bcs,
      ccd ? JPH_MotionQuality_LinearCast : JPH_MotionQuality_Discrete);
  if (mass > 0) {  /* override the density-derived mass, keep shape-derived inertia */
    JPH_BodyCreationSettings_SetOverrideMassProperties(bcs, JPH_OverrideMassProperties_CalculateInertia);
    JPH_MassProperties mp; JPH_BodyCreationSettings_GetMassPropertiesOverride(bcs, &mp);
    mp.mass = (float)mass;
    JPH_BodyCreationSettings_SetMassPropertiesOverride(bcs, &mp);
  }
  JPH_BodyID id = JPH_BodyInterface_CreateAndAddBody(w->bi, bcs,
      activate ? JPH_Activation_Activate : JPH_Activation_DontActivate);
  JPH_BodyCreationSettings_Destroy(bcs);
  return mrb_int_value(mrb, (mrb_int)id);
}

static mrb_value jolt_remove_body(mrb_state *mrb, mrb_value self) {
  mrb_int id; mrb_get_args(mrb, "i", &id);
  JPH_BodyInterface_RemoveAndDestroyBody(jolt_world(mrb, self)->bi, (JPH_BodyID)id);
  return self;
}

static mrb_value jolt_position(mrb_state *mrb, mrb_value self) {
  mrb_int id; mrb_get_args(mrb, "i", &id);
  JPH_RVec3 p; JPH_BodyInterface_GetPosition(jolt_world(mrb, self)->bi, (JPH_BodyID)id, &p);
  return vec3_ary(mrb, p.x, p.y, p.z);
}
static mrb_value jolt_com_position(mrb_state *mrb, mrb_value self) {
  mrb_int id; mrb_get_args(mrb, "i", &id);
  JPH_RVec3 p;
  JPH_BodyInterface_GetCenterOfMassPosition(jolt_world(mrb, self)->bi, (JPH_BodyID)id, &p);
  return vec3_ary(mrb, p.x, p.y, p.z);
}
static mrb_value jolt_rotation(mrb_state *mrb, mrb_value self) {
  mrb_int id; mrb_get_args(mrb, "i", &id);
  JPH_Quat q; JPH_BodyInterface_GetRotation(jolt_world(mrb, self)->bi, (JPH_BodyID)id, &q);
  mrb_value a = mrb_ary_new_capa(mrb, 4);
  mrb_ary_push(mrb, a, mrb_float_value(mrb, q.x));
  mrb_ary_push(mrb, a, mrb_float_value(mrb, q.y));
  mrb_ary_push(mrb, a, mrb_float_value(mrb, q.z));
  mrb_ary_push(mrb, a, mrb_float_value(mrb, q.w));
  return a;
}

/* _set_transform(id, px,py,pz, qx,qy,qz,qw, activate) */
static mrb_value jolt_set_transform(mrb_state *mrb, mrb_value self) {
  mrb_int id; mrb_float px,py,pz, qx,qy,qz,qw; mrb_bool act;
  mrb_get_args(mrb, "ifffffffb", &id, &px,&py,&pz, &qx,&qy,&qz,&qw, &act);
  JPH_RVec3 p = { (float)px,(float)py,(float)pz };
  JPH_Quat  q = { (float)qx,(float)qy,(float)qz,(float)qw };
  JPH_BodyInterface_SetPositionAndRotation(jolt_world(mrb, self)->bi, (JPH_BodyID)id, &p, &q,
      act ? JPH_Activation_Activate : JPH_Activation_DontActivate);
  return self;
}

static mrb_value jolt_linear_velocity(mrb_state *mrb, mrb_value self) {
  mrb_int id; mrb_get_args(mrb, "i", &id);
  JPH_Vec3 v; JPH_BodyInterface_GetLinearVelocity(jolt_world(mrb, self)->bi, (JPH_BodyID)id, &v);
  return vec3_ary(mrb, v.x, v.y, v.z);
}
static mrb_value jolt_set_linear_velocity(mrb_state *mrb, mrb_value self) {
  mrb_int id; mrb_float x,y,z; mrb_get_args(mrb, "ifff", &id, &x,&y,&z);
  JPH_Vec3 v = { (float)x,(float)y,(float)z };
  JPH_BodyInterface_SetLinearVelocity(jolt_world(mrb, self)->bi, (JPH_BodyID)id, &v);
  return self;
}
static mrb_value jolt_angular_velocity(mrb_state *mrb, mrb_value self) {
  mrb_int id; mrb_get_args(mrb, "i", &id);
  JPH_Vec3 v; JPH_BodyInterface_GetAngularVelocity(jolt_world(mrb, self)->bi, (JPH_BodyID)id, &v);
  return vec3_ary(mrb, v.x, v.y, v.z);
}
static mrb_value jolt_set_angular_velocity(mrb_state *mrb, mrb_value self) {
  mrb_int id; mrb_float x,y,z; mrb_get_args(mrb, "ifff", &id, &x,&y,&z);
  JPH_Vec3 v = { (float)x,(float)y,(float)z };
  JPH_BodyInterface_SetAngularVelocity(jolt_world(mrb, self)->bi, (JPH_BodyID)id, &v);
  return self;
}

static mrb_value jolt_add_force(mrb_state *mrb, mrb_value self) {
  mrb_int id; mrb_float x,y,z; mrb_get_args(mrb, "ifff", &id, &x,&y,&z);
  JPH_Vec3 v = { (float)x,(float)y,(float)z };
  JPH_BodyInterface_AddForce(jolt_world(mrb, self)->bi, (JPH_BodyID)id, &v);
  return self;
}
static mrb_value jolt_add_impulse(mrb_state *mrb, mrb_value self) {
  mrb_int id; mrb_float x,y,z; mrb_get_args(mrb, "ifff", &id, &x,&y,&z);
  JPH_Vec3 v = { (float)x,(float)y,(float)z };
  JPH_BodyInterface_AddImpulse(jolt_world(mrb, self)->bi, (JPH_BodyID)id, &v);
  return self;
}
static mrb_value jolt_add_torque(mrb_state *mrb, mrb_value self) {
  mrb_int id; mrb_float x,y,z; mrb_get_args(mrb, "ifff", &id, &x,&y,&z);
  JPH_Vec3 v = { (float)x,(float)y,(float)z };
  JPH_BodyInterface_AddTorque(jolt_world(mrb, self)->bi, (JPH_BodyID)id, &v);
  return self;
}

static mrb_value jolt_is_active(mrb_state *mrb, mrb_value self) {
  mrb_int id; mrb_get_args(mrb, "i", &id);
  return mrb_bool_value(JPH_BodyInterface_IsActive(jolt_world(mrb, self)->bi, (JPH_BodyID)id));
}
static mrb_value jolt_activate(mrb_state *mrb, mrb_value self) {
  mrb_int id; mrb_get_args(mrb, "i", &id);
  JPH_BodyInterface_ActivateBody(jolt_world(mrb, self)->bi, (JPH_BodyID)id);
  return self;
}
static mrb_value jolt_deactivate(mrb_state *mrb, mrb_value self) {
  mrb_int id; mrb_get_args(mrb, "i", &id);
  JPH_BodyInterface_DeactivateBody(jolt_world(mrb, self)->bi, (JPH_BodyID)id);
  return self;
}

/* _raycast(ox,oy,oz, dx,dy,dz) -> [body_id, fraction, hx,hy,hz] | nil */
static mrb_value jolt_raycast(mrb_state *mrb, mrb_value self) {
  mrb_float ox,oy,oz, dx,dy,dz;
  mrb_get_args(mrb, "ffffff", &ox,&oy,&oz, &dx,&dy,&dz);
  jolt_world_t *w = jolt_world(mrb, self);
  const JPH_NarrowPhaseQuery *q = JPH_PhysicsSystem_GetNarrowPhaseQuery(w->sys);
  JPH_RVec3 origin = { (float)ox,(float)oy,(float)oz };
  JPH_Vec3  dir    = { (float)dx,(float)dy,(float)dz };
  JPH_RayCastResult hit;
  if (!JPH_NarrowPhaseQuery_CastRay(q, &origin, &dir, &hit, NULL, NULL, NULL))
    return mrb_nil_value();
  float hx = (float)(ox + dx * hit.fraction);
  float hy = (float)(oy + dy * hit.fraction);
  float hz = (float)(oz + dz * hit.fraction);
  JPH_Vec3 n = { 0, 0, 0 };  /* surface normal at the hit point */
  JPH_Body *hb = jolt_body_for(w, hit.bodyID);
  if (hb) { JPH_RVec3 hp = { hx, hy, hz };
            JPH_Body_GetWorldSpaceSurfaceNormal(hb, hit.subShapeID2, &hp, &n); }
  mrb_value a = mrb_ary_new_capa(mrb, 8);
  mrb_ary_push(mrb, a, mrb_int_value(mrb, (mrb_int)hit.bodyID));
  mrb_ary_push(mrb, a, mrb_float_value(mrb, hit.fraction));
  mrb_ary_push(mrb, a, mrb_float_value(mrb, hx));
  mrb_ary_push(mrb, a, mrb_float_value(mrb, hy));
  mrb_ary_push(mrb, a, mrb_float_value(mrb, hz));
  mrb_ary_push(mrb, a, mrb_float_value(mrb, n.x));
  mrb_ary_push(mrb, a, mrb_float_value(mrb, n.y));
  mrb_ary_push(mrb, a, mrb_float_value(mrb, n.z));
  return a;
}

/* --- body properties (get/set) --- */
static mrb_value jolt_user_data(mrb_state *mrb, mrb_value self) {
  mrb_int id; mrb_get_args(mrb, "i", &id);
  return mrb_int_value(mrb, (mrb_int)JPH_BodyInterface_GetUserData(jolt_world(mrb, self)->bi, (JPH_BodyID)id));
}
static mrb_value jolt_set_user_data(mrb_state *mrb, mrb_value self) {
  mrb_int id, v; mrb_get_args(mrb, "ii", &id, &v);
  JPH_BodyInterface_SetUserData(jolt_world(mrb, self)->bi, (JPH_BodyID)id, (uint64_t)v);
  return self;
}
static mrb_value jolt_motion_type(mrb_state *mrb, mrb_value self) {
  mrb_int id; mrb_get_args(mrb, "i", &id);
  return mrb_int_value(mrb, (mrb_int)JPH_BodyInterface_GetMotionType(jolt_world(mrb, self)->bi, (JPH_BodyID)id));
}
static mrb_value jolt_set_motion_type(mrb_state *mrb, mrb_value self) {
  mrb_int id, mt; mrb_bool act; mrb_get_args(mrb, "iib", &id, &mt, &act);
  JPH_BodyInterface_SetMotionType(jolt_world(mrb, self)->bi, (JPH_BodyID)id, (JPH_MotionType)mt,
      act ? JPH_Activation_Activate : JPH_Activation_DontActivate);
  return self;
}
static mrb_value jolt_friction(mrb_state *mrb, mrb_value self) {
  mrb_int id; mrb_get_args(mrb, "i", &id);
  return mrb_float_value(mrb, JPH_BodyInterface_GetFriction(jolt_world(mrb, self)->bi, (JPH_BodyID)id));
}
static mrb_value jolt_set_friction(mrb_state *mrb, mrb_value self) {
  mrb_int id; mrb_float v; mrb_get_args(mrb, "if", &id, &v);
  JPH_BodyInterface_SetFriction(jolt_world(mrb, self)->bi, (JPH_BodyID)id, (float)v);
  return self;
}
static mrb_value jolt_restitution(mrb_state *mrb, mrb_value self) {
  mrb_int id; mrb_get_args(mrb, "i", &id);
  return mrb_float_value(mrb, JPH_BodyInterface_GetRestitution(jolt_world(mrb, self)->bi, (JPH_BodyID)id));
}
static mrb_value jolt_set_restitution(mrb_state *mrb, mrb_value self) {
  mrb_int id; mrb_float v; mrb_get_args(mrb, "if", &id, &v);
  JPH_BodyInterface_SetRestitution(jolt_world(mrb, self)->bi, (JPH_BodyID)id, (float)v);
  return self;
}
static mrb_value jolt_gravity_factor(mrb_state *mrb, mrb_value self) {
  mrb_int id; mrb_get_args(mrb, "i", &id);
  return mrb_float_value(mrb, JPH_BodyInterface_GetGravityFactor(jolt_world(mrb, self)->bi, (JPH_BodyID)id));
}
static mrb_value jolt_set_gravity_factor(mrb_state *mrb, mrb_value self) {
  mrb_int id; mrb_float v; mrb_get_args(mrb, "if", &id, &v);
  JPH_BodyInterface_SetGravityFactor(jolt_world(mrb, self)->bi, (JPH_BodyID)id, (float)v);
  return self;
}

static mrb_value jolt_set_sensor(mrb_state *mrb, mrb_value self) {
  mrb_int id; mrb_bool v; mrb_get_args(mrb, "ib", &id, &v);
  JPH_BodyInterface_SetIsSensor(jolt_world(mrb, self)->bi, (JPH_BodyID)id, v);
  return self;
}
static mrb_value jolt_set_ccd(mrb_state *mrb, mrb_value self) {
  mrb_int id; mrb_bool v; mrb_get_args(mrb, "ib", &id, &v);
  JPH_BodyInterface_SetMotionQuality(jolt_world(mrb, self)->bi, (JPH_BodyID)id,
      v ? JPH_MotionQuality_LinearCast : JPH_MotionQuality_Discrete);
  return self;
}

/* --- point overlap query --- */
typedef struct { mrb_state *mrb; mrb_value arr; } jolt_collect_t;
static float JPH_API_CALL jolt_collect_point(void *ud, const JPH_CollidePointResult *r) {
  jolt_collect_t *c = (jolt_collect_t *)ud;
  mrb_ary_push(c->mrb, c->arr, mrb_int_value(c->mrb, (mrb_int)r->bodyID));
  return 1.0e30f; /* keep collecting (no early-out) */
}
/* _overlap_point(x,y,z) -> Array of body ids whose shape contains the point */
static mrb_value jolt_overlap_point(mrb_state *mrb, mrb_value self) {
  mrb_float x, y, z; mrb_get_args(mrb, "fff", &x, &y, &z);
  jolt_world_t *w = jolt_world(mrb, self);
  const JPH_NarrowPhaseQuery *q = JPH_PhysicsSystem_GetNarrowPhaseQuery(w->sys);
  JPH_RVec3 p = { (float)x, (float)y, (float)z };
  jolt_collect_t ctx = { mrb, mrb_ary_new(mrb) };
  JPH_NarrowPhaseQuery_CollidePoint(q, &p, jolt_collect_point, &ctx, NULL, NULL, NULL, NULL);
  return ctx.arr;
}

/* ----------------------------------------------------------- constraints --- */
typedef struct { JPH_Constraint *c; JPH_PhysicsSystem *sys; jolt_token_t *token; } jolt_constraint_t;
static void jolt_constraint_free(mrb_state *mrb, void *p) {
  jolt_constraint_t *c = p;
  if (c) {
    /* skip ALL Jolt calls if the world is already gone (see jolt_ragdoll_free) */
    if (c->c && c->token && c->token->alive) {
      if (c->sys) JPH_PhysicsSystem_RemoveConstraint(c->sys, c->c);
      JPH_Constraint_Destroy(c->c);
    }
    jolt_token_release(c->token);
    mrb_free(mrb, c);
  }
}
static const mrb_data_type jolt_constraint_type = { "Jolt::Constraint", jolt_constraint_free };

static mrb_value wrap_constraint(mrb_state *mrb, mrb_value world, JPH_Constraint *con, jolt_world_t *w) {
  JPH_PhysicsSystem_AddConstraint(w->sys, con);
  jolt_constraint_t *c = mrb_malloc(mrb, sizeof(jolt_constraint_t));
  c->c = con; c->sys = w->sys; c->token = jolt_token_acquire(w->token);
  struct RClass *m = mrb_module_get(mrb, "Jolt");
  struct RClass *cls = mrb_class_get_under(mrb, m, "Constraint");
  mrb_value obj = mrb_obj_value(mrb_data_object_alloc(mrb, cls, c, &jolt_constraint_type));
  mrb_iv_set(mrb, obj, mrb_intern_lit(mrb, "@world"), world);
  return obj;
}
static JPH_Vec3 jolt_norm(JPH_Vec3 v) {
  float L = sqrtf(v.x*v.x + v.y*v.y + v.z*v.z);
  if (L > 1e-6f) { v.x/=L; v.y/=L; v.z/=L; }
  return v;
}

static mrb_value jolt_c_fixed(mrb_state *mrb, mrb_value self) {
  mrb_int a, b; mrb_get_args(mrb, "ii", &a, &b);
  jolt_world_t *w = jolt_world(mrb, self);
  JPH_FixedConstraintSettings s; JPH_FixedConstraintSettings_Init(&s);
  s.space = JPH_ConstraintSpace_WorldSpace; s.autoDetectPoint = true;
  JPH_Constraint *con = (JPH_Constraint *)JPH_FixedConstraint_Create(&s,
      jolt_body_for(w, (JPH_BodyID)a), jolt_body_for(w, (JPH_BodyID)b));
  return wrap_constraint(mrb, self, con, w);
}
static mrb_value jolt_c_point(mrb_state *mrb, mrb_value self) {
  mrb_int a, b; mrb_float px, py, pz; mrb_get_args(mrb, "iifff", &a, &b, &px, &py, &pz);
  jolt_world_t *w = jolt_world(mrb, self);
  JPH_PointConstraintSettings s; JPH_PointConstraintSettings_Init(&s);
  s.space = JPH_ConstraintSpace_WorldSpace;
  s.point1 = (JPH_RVec3){ (float)px, (float)py, (float)pz };
  s.point2 = s.point1;
  JPH_Constraint *con = (JPH_Constraint *)JPH_PointConstraint_Create(&s,
      jolt_body_for(w, (JPH_BodyID)a), jolt_body_for(w, (JPH_BodyID)b));
  return wrap_constraint(mrb, self, con, w);
}
static mrb_value jolt_c_distance(mrb_state *mrb, mrb_value self) {
  mrb_int a, b; mrb_float ax,ay,az, bx,by,bz, mn, mx;
  mrb_get_args(mrb, "iiffffffff", &a, &b, &ax,&ay,&az, &bx,&by,&bz, &mn, &mx);
  jolt_world_t *w = jolt_world(mrb, self);
  JPH_DistanceConstraintSettings s; JPH_DistanceConstraintSettings_Init(&s);
  s.space = JPH_ConstraintSpace_WorldSpace;
  s.point1 = (JPH_RVec3){ (float)ax, (float)ay, (float)az };
  s.point2 = (JPH_RVec3){ (float)bx, (float)by, (float)bz };
  s.minDistance = (float)mn; s.maxDistance = (float)mx;
  JPH_Constraint *con = (JPH_Constraint *)JPH_DistanceConstraint_Create(&s,
      jolt_body_for(w, (JPH_BodyID)a), jolt_body_for(w, (JPH_BodyID)b));
  return wrap_constraint(mrb, self, con, w);
}
static mrb_value jolt_c_hinge(mrb_state *mrb, mrb_value self) {
  mrb_int a, b; mrb_float px,py,pz, ax,ay,az, mn, mx;
  mrb_get_args(mrb, "iiffffffff", &a, &b, &px,&py,&pz, &ax,&ay,&az, &mn, &mx);
  jolt_world_t *w = jolt_world(mrb, self);
  JPH_HingeConstraintSettings s; JPH_HingeConstraintSettings_Init(&s);
  s.space = JPH_ConstraintSpace_WorldSpace;
  JPH_Vec3 axis = jolt_norm((JPH_Vec3){ (float)ax, (float)ay, (float)az });
  JPH_Vec3 nrm  = jolt_perp(axis);
  s.point1 = (JPH_RVec3){ (float)px, (float)py, (float)pz }; s.point2 = s.point1;
  s.hingeAxis1 = axis; s.hingeAxis2 = axis;
  s.normalAxis1 = nrm; s.normalAxis2 = nrm;
  s.limitsMin = (float)mn; s.limitsMax = (float)mx;
  JPH_Constraint *con = (JPH_Constraint *)JPH_HingeConstraint_Create(&s,
      jolt_body_for(w, (JPH_BodyID)a), jolt_body_for(w, (JPH_BodyID)b));
  return wrap_constraint(mrb, self, con, w);
}
static mrb_value jolt_c_slider(mrb_state *mrb, mrb_value self) {
  mrb_int a, b; mrb_float px,py,pz, ax,ay,az, mn, mx;
  mrb_get_args(mrb, "iiffffffff", &a, &b, &px,&py,&pz, &ax,&ay,&az, &mn, &mx);
  jolt_world_t *w = jolt_world(mrb, self);
  JPH_SliderConstraintSettings s; JPH_SliderConstraintSettings_Init(&s);
  s.space = JPH_ConstraintSpace_WorldSpace; s.autoDetectPoint = false;
  JPH_Vec3 axis = jolt_norm((JPH_Vec3){ (float)ax, (float)ay, (float)az });
  JPH_Vec3 nrm  = jolt_perp(axis);
  s.point1 = (JPH_RVec3){ (float)px, (float)py, (float)pz }; s.point2 = s.point1;
  s.sliderAxis1 = axis; s.sliderAxis2 = axis;
  s.normalAxis1 = nrm; s.normalAxis2 = nrm;
  s.limitsMin = (float)mn; s.limitsMax = (float)mx;
  JPH_Constraint *con = (JPH_Constraint *)JPH_SliderConstraint_Create(&s,
      jolt_body_for(w, (JPH_BodyID)a), jolt_body_for(w, (JPH_BodyID)b));
  return wrap_constraint(mrb, self, con, w);
}
static mrb_value jolt_c_cone(mrb_state *mrb, mrb_value self) {
  mrb_int a, b; mrb_float px,py,pz, ax,ay,az, half;
  mrb_get_args(mrb, "iifffffff", &a, &b, &px,&py,&pz, &ax,&ay,&az, &half);
  jolt_world_t *w = jolt_world(mrb, self);
  JPH_ConeConstraintSettings s; JPH_ConeConstraintSettings_Init(&s);
  s.space = JPH_ConstraintSpace_WorldSpace;
  JPH_Vec3 axis = jolt_norm((JPH_Vec3){ (float)ax, (float)ay, (float)az });
  s.point1 = (JPH_RVec3){ (float)px, (float)py, (float)pz }; s.point2 = s.point1;
  s.twistAxis1 = axis; s.twistAxis2 = axis;
  s.halfConeAngle = (float)half;
  JPH_Constraint *con = (JPH_Constraint *)JPH_ConeConstraint_Create(&s,
      jolt_body_for(w, (JPH_BodyID)a), jolt_body_for(w, (JPH_BodyID)b));
  return wrap_constraint(mrb, self, con, w);
}
static mrb_value jolt_constraint_remove(mrb_state *mrb, mrb_value self) {
  jolt_constraint_t *c = mrb_data_get_ptr(mrb, self, &jolt_constraint_type);
  if (c && c->c) {
    if (c->sys && c->token && c->token->alive) JPH_PhysicsSystem_RemoveConstraint(c->sys, c->c);
    JPH_Constraint_Destroy(c->c);
    c->c = NULL;
  }
  return self;
}

/* -------------------------------------------------------------- ragdoll --- */
/* A Ragdoll: a tree of dynamic bodies (one per skeleton joint) wired together
 * with swing-twist (cone + twist limit) constraints, so a humanoid collapses
 * believably. Built in one shot from a packed parts array (the Ruby layer turns
 * friendly hashes into it). Each part array element is:
 *   [0]=name(str) [1]=parent_index(int,-1=root) [2]=shape
 *   [3..5]=position [6..9]=rotation quat [10]=motion(int) [11]=mass(<=0 derive)
 *   [12..14]=joint world point  [15..17]=twist axis  [18..20]=plane axis
 *   [21]=normal-half-cone(rad)  [22]=plane-half-cone(rad)
 *   [23]=twist-min(rad)         [24]=twist-max(rad)            (12.. ignored for root) */
typedef struct { JPH_Ragdoll *rd; JPH_PhysicsSystem *sys; bool in_system; jolt_token_t *token; } jolt_ragdoll_t;

static void jolt_ragdoll_free(mrb_state *mrb, void *p) {
  jolt_ragdoll_t *r = p;
  if (r) {
    /* Only touch Jolt while the world (and its system + bodies) still exists. If
     * the world was already destroyed (shutdown, arbitrary free order), the
     * ragdoll's bodies/constraints are gone too — calling Destroy would double-
     * free, so skip and let the process reclaim it. */
    if (r->rd && r->token && r->token->alive) {
      if (r->in_system) JPH_Ragdoll_RemoveFromPhysicsSystem(r->rd, true);
      JPH_Ragdoll_Destroy(r->rd);
    }
    jolt_token_release(r->token);
    mrb_free(mrb, r);
  }
}
static const mrb_data_type jolt_ragdoll_type = { "Jolt::Ragdoll", jolt_ragdoll_free };

static jolt_ragdoll_t *jolt_ragdoll(mrb_state *mrb, mrb_value self) {
  jolt_ragdoll_t *r = mrb_data_get_ptr(mrb, self, &jolt_ragdoll_type);
  if (!r || !r->rd) mrb_raise(mrb, E_RUNTIME_ERROR, "ragdoll not initialized");
  return r;
}

static float partf(mrb_state *mrb, mrb_value part, mrb_int k) {
  return (float)mrb_as_float(mrb, mrb_ary_ref(mrb, part, k));
}

/* world._ragdoll(parts, user_data) -> Jolt::Ragdoll */
static mrb_value jolt_world_ragdoll(mrb_state *mrb, mrb_value self) {
  mrb_value parts; mrb_int user_data;
  mrb_get_args(mrb, "Ai", &parts, &user_data);
  jolt_world_t *w = jolt_world(mrb, self);
  mrb_int n = RARRAY_LEN(parts);
  if (n < 1) mrb_raise(mrb, E_ARGUMENT_ERROR, "ragdoll needs >= 1 part");

  JPH_Skeleton *skel = JPH_Skeleton_Create();
  for (mrb_int i = 0; i < n; i++) {
    mrb_value part = mrb_ary_ref(mrb, parts, i);
    const char *name = mrb_str_to_cstr(mrb, mrb_ary_ref(mrb, part, 0));
    mrb_int parent   = mrb_as_int(mrb, mrb_ary_ref(mrb, part, 1));
    JPH_Skeleton_AddJoint2(skel, name, (int)parent);
  }
  JPH_Skeleton_CalculateParentJointIndices(skel);

  JPH_RagdollSettings *rs = JPH_RagdollSettings_Create();
  JPH_RagdollSettings_SetSkeleton(rs, skel);
  JPH_RagdollSettings_ResizeParts(rs, (int)n);
  for (mrb_int i = 0; i < n; i++) {
    mrb_value part = mrb_ary_ref(mrb, parts, i);
    mrb_int parent = mrb_as_int(mrb, mrb_ary_ref(mrb, part, 1));
    mrb_int motion = mrb_as_int(mrb, mrb_ary_ref(mrb, part, 10));
    float   mass   = partf(mrb, part, 11);
    JPH_RVec3 pos = { partf(mrb,part,3), partf(mrb,part,4), partf(mrb,part,5) };
    JPH_Quat  rot = { partf(mrb,part,6), partf(mrb,part,7), partf(mrb,part,8), partf(mrb,part,9) };
    JPH_RagdollSettings_SetPartShape(rs, (int)i, shape_ptr(mrb, mrb_ary_ref(mrb, part, 2)));
    JPH_RagdollSettings_SetPartPosition(rs, (int)i, &pos);
    JPH_RagdollSettings_SetPartRotation(rs, (int)i, &rot);
    JPH_RagdollSettings_SetPartMotionType(rs, (int)i, (JPH_MotionType)motion);
    JPH_RagdollSettings_SetPartObjectLayer(rs, (int)i,
        (motion == JPH_MotionType_Static) ? L_STATIC : L_MOVING);
    if (mass > 0) JPH_RagdollSettings_SetPartMassProperties(rs, (int)i, mass);
    if (parent >= 0) {
      JPH_SwingTwistConstraintSettings s; JPH_SwingTwistConstraintSettings_Init(&s);
      s.space = JPH_ConstraintSpace_WorldSpace;
      JPH_RVec3 jp = { partf(mrb,part,12), partf(mrb,part,13), partf(mrb,part,14) };
      JPH_Vec3 tw = jolt_norm((JPH_Vec3){ partf(mrb,part,15), partf(mrb,part,16), partf(mrb,part,17) });
      JPH_Vec3 pl = jolt_norm((JPH_Vec3){ partf(mrb,part,18), partf(mrb,part,19), partf(mrb,part,20) });
      s.position1 = jp; s.position2 = jp;
      s.twistAxis1 = tw; s.twistAxis2 = tw;
      s.planeAxis1 = pl; s.planeAxis2 = pl;
      s.normalHalfConeAngle = partf(mrb,part,21);
      s.planeHalfConeAngle  = partf(mrb,part,22);
      s.twistMinAngle       = partf(mrb,part,23);
      s.twistMaxAngle       = partf(mrb,part,24);
      JPH_RagdollSettings_SetPartToParent(rs, (int)i, &s);
    }
  }

  JPH_RagdollSettings_Stabilize(rs);                                  /* tune masses */
  JPH_RagdollSettings_DisableParentChildCollisions(rs, NULL, 0.0f);   /* no self-collide adjacents */
  JPH_RagdollSettings_CalculateBodyIndexToConstraintIndex(rs);
  JPH_Ragdoll *rd = JPH_RagdollSettings_CreateRagdoll(rs, w->sys, 0, (uint64_t)user_data);
  /* the ragdoll holds refs to settings (which holds the skeleton); release ours */
  JPH_RagdollSettings_Destroy(rs);
  JPH_Skeleton_Destroy(skel);
  if (!rd) mrb_raise(mrb, E_RUNTIME_ERROR, "failed to create ragdoll");
  JPH_Ragdoll_AddToPhysicsSystem(rd, JPH_Activation_Activate, true);

  jolt_ragdoll_t *r = mrb_malloc(mrb, sizeof(jolt_ragdoll_t));
  r->rd = rd; r->sys = w->sys; r->in_system = true; r->token = jolt_token_acquire(w->token);
  struct RClass *m = mrb_module_get(mrb, "Jolt");
  struct RClass *cls = mrb_class_get_under(mrb, m, "Ragdoll");
  mrb_value obj = mrb_obj_value(mrb_data_object_alloc(mrb, cls, r, &jolt_ragdoll_type));
  mrb_iv_set(mrb, obj, mrb_intern_lit(mrb, "@world"), self); /* keep the world alive */
  return obj;
}

static mrb_value jolt_ragdoll_body_count(mrb_state *mrb, mrb_value self) {
  return mrb_int_value(mrb, JPH_Ragdoll_GetBodyCount(jolt_ragdoll(mrb, self)->rd));
}
static mrb_value jolt_ragdoll_body_id(mrb_state *mrb, mrb_value self) {
  mrb_int i; mrb_get_args(mrb, "i", &i);
  return mrb_int_value(mrb, (mrb_int)JPH_Ragdoll_GetBodyID(jolt_ragdoll(mrb, self)->rd, (int)i));
}
static mrb_value jolt_ragdoll_activate(mrb_state *mrb, mrb_value self) {
  JPH_Ragdoll_Activate(jolt_ragdoll(mrb, self)->rd, true);
  return self;
}
static mrb_value jolt_ragdoll_remove(mrb_state *mrb, mrb_value self) {
  jolt_ragdoll_t *r = mrb_data_get_ptr(mrb, self, &jolt_ragdoll_type);
  if (r && r->rd && r->in_system) {
    if (r->token && r->token->alive) JPH_Ragdoll_RemoveFromPhysicsSystem(r->rd, true);
    r->in_system = false;
  }
  return self;
}

/* ------------------------------------------------------------- character -- */
/* A CharacterVirtual: a kinematic, fully-controlled player capsule with
 * stair-stepping / slope handling. Holds the physics system so Update can run;
 * the Ruby wrapper keeps its world alive via @world. */
typedef struct { JPH_CharacterVirtual *ch; JPH_PhysicsSystem *sys; } jolt_char_t;

static void jolt_char_free(mrb_state *mrb, void *p) {
  jolt_char_t *c = p;
  if (c) {
    if (c->ch) JPH_CharacterBase_Destroy((JPH_CharacterBase *)c->ch);
    mrb_free(mrb, c);
  }
}
static const mrb_data_type jolt_char_type = { "Jolt::Character", jolt_char_free };

static jolt_char_t *jolt_char(mrb_state *mrb, mrb_value self) {
  jolt_char_t *c = mrb_data_get_ptr(mrb, self, &jolt_char_type);
  if (!c || !c->ch) mrb_raise(mrb, E_RUNTIME_ERROR, "character not initialized");
  return c;
}

/* world._character(shape, px,py,pz, slope_deg, mass) -> Jolt::Character */
static mrb_value jolt_world_character(mrb_state *mrb, mrb_value self) {
  mrb_value shape; mrb_float px, py, pz, slope, mass;
  mrb_get_args(mrb, "offfff", &shape, &px, &py, &pz, &slope, &mass);
  jolt_world_t *w = jolt_world(mrb, self);

  JPH_CharacterVirtualSettings cs;
  JPH_CharacterVirtualSettings_Init(&cs);
  cs.base.shape = shape_ptr(mrb, shape);
  cs.base.up = (JPH_Vec3){ 0, 1, 0 };
  cs.base.supportingVolume = (JPH_Plane){ { 0, 1, 0 }, -1.0e10f }; /* accept all; slope filters */
  cs.base.maxSlopeAngle = (float)(slope * 3.14159265358979 / 180.0);
  cs.mass = (float)mass;

  JPH_RVec3 pos = { (float)px, (float)py, (float)pz };
  JPH_CharacterVirtual *ch = JPH_CharacterVirtual_Create(&cs, &pos, NULL, 0, w->sys);
  if (!ch) mrb_raise(mrb, E_RUNTIME_ERROR, "failed to create character");

  jolt_char_t *c = mrb_malloc(mrb, sizeof(jolt_char_t));
  c->ch = ch; c->sys = w->sys;
  struct RClass *m = mrb_module_get(mrb, "Jolt");
  struct RClass *cls = mrb_class_get_under(mrb, m, "Character");
  mrb_value obj = mrb_obj_value(mrb_data_object_alloc(mrb, cls, c, &jolt_char_type));
  mrb_iv_set(mrb, obj, mrb_intern_lit(mrb, "@world"), self); /* keep the world alive */
  return obj;
}

static mrb_value jolt_char_update(mrb_state *mrb, mrb_value self) {
  mrb_float dt; mrb_get_args(mrb, "f", &dt);
  jolt_char_t *c = jolt_char(mrb, self);
  /* ExtendedUpdate (not basic Update) gives stair-stepping + stick-to-floor.
     Jolt's documented defaults; step-up height = walkStairsStepUp.y (0.4m). */
  JPH_ExtendedUpdateSettings su;
  su.stickToFloorStepDown = (JPH_Vec3){ 0, -0.5f, 0 };
  su.walkStairsStepUp     = (JPH_Vec3){ 0,  0.4f, 0 };
  su.walkStairsMinStepForward      = 0.02f;
  su.walkStairsStepForwardTest     = 0.15f;
  su.walkStairsCosAngleForwardContact = 0.2588f; /* cos(75 deg) */
  su.walkStairsStepDownExtra = (JPH_Vec3){ 0, 0, 0 };
  JPH_CharacterVirtual_ExtendedUpdate(c->ch, (float)dt, &su, L_MOVING, c->sys, NULL, NULL);
  return self;
}
static mrb_value jolt_char_position(mrb_state *mrb, mrb_value self) {
  JPH_RVec3 p; JPH_CharacterVirtual_GetPosition(jolt_char(mrb, self)->ch, &p);
  return vec3_ary(mrb, p.x, p.y, p.z);
}
static mrb_value jolt_char_set_position(mrb_state *mrb, mrb_value self) {
  mrb_float x, y, z; mrb_get_args(mrb, "fff", &x, &y, &z);
  JPH_RVec3 p = { (float)x, (float)y, (float)z };
  JPH_CharacterVirtual_SetPosition(jolt_char(mrb, self)->ch, &p);
  return self;
}
static mrb_value jolt_char_velocity(mrb_state *mrb, mrb_value self) {
  JPH_Vec3 v; JPH_CharacterVirtual_GetLinearVelocity(jolt_char(mrb, self)->ch, &v);
  return vec3_ary(mrb, v.x, v.y, v.z);
}
static mrb_value jolt_char_set_velocity(mrb_state *mrb, mrb_value self) {
  mrb_float x, y, z; mrb_get_args(mrb, "fff", &x, &y, &z);
  JPH_Vec3 v = { (float)x, (float)y, (float)z };
  JPH_CharacterVirtual_SetLinearVelocity(jolt_char(mrb, self)->ch, &v);
  return self;
}
static mrb_value jolt_char_ground_state(mrb_state *mrb, mrb_value self) {
  return mrb_int_value(mrb,
      (mrb_int)JPH_CharacterBase_GetGroundState((JPH_CharacterBase *)jolt_char(mrb, self)->ch));
}
static mrb_value jolt_char_ground_normal(mrb_state *mrb, mrb_value self) {
  JPH_Vec3 n; JPH_CharacterBase_GetGroundNormal((JPH_CharacterBase *)jolt_char(mrb, self)->ch, &n);
  return vec3_ary(mrb, n.x, n.y, n.z);
}
static mrb_value jolt_char_supported(mrb_state *mrb, mrb_value self) {
  return mrb_bool_value(JPH_CharacterBase_IsSupported((JPH_CharacterBase *)jolt_char(mrb, self)->ch));
}
/* velocity of the surface the character stands on (a moving platform/elevator).
   Add it to the character's velocity to ride along. Zero when not supported. */
static mrb_value jolt_char_ground_velocity(mrb_state *mrb, mrb_value self) {
  JPH_Vec3 v; JPH_CharacterBase_GetGroundVelocity((JPH_CharacterBase *)jolt_char(mrb, self)->ch, &v);
  return vec3_ary(mrb, v.x, v.y, v.z);
}
/* body id of the surface under the character (the platform). Invalid id when
   airborne — the Ruby layer maps that to nil via on_ground?. */
static mrb_value jolt_char_ground_body_id(mrb_state *mrb, mrb_value self) {
  return mrb_int_value(mrb,
      (mrb_int)JPH_CharacterBase_GetGroundBodyId((JPH_CharacterBase *)jolt_char(mrb, self)->ch));
}
/* max force (N) the character can exert on dynamic bodies it walks into. The
   Jolt default (100 N) is too weak to shove heavy default-density spheres, so
   games raise this when they want the player to push props around. */
static mrb_value jolt_char_set_max_strength(mrb_state *mrb, mrb_value self) {
  mrb_float v; mrb_get_args(mrb, "f", &v);
  JPH_CharacterVirtual_SetMaxStrength(jolt_char(mrb, self)->ch, (float)v);
  return self;
}
static mrb_value jolt_char_max_strength(mrb_state *mrb, mrb_value self) {
  return mrb_float_value(mrb, JPH_CharacterVirtual_GetMaxStrength(jolt_char(mrb, self)->ch));
}
/* effective mass used when dynamic bodies collide with the character (higher =
   harder to shove the character; it is still kinematic / infinite-mass to gravity). */
static mrb_value jolt_char_set_mass(mrb_state *mrb, mrb_value self) {
  mrb_float v; mrb_get_args(mrb, "f", &v);
  JPH_CharacterVirtual_SetMass(jolt_char(mrb, self)->ch, (float)v);
  return self;
}

/* ------------------------------------------------------------------- init -- */
void mrb_jolt_gem_init(mrb_state *mrb) {
  JPH_Init();
  g_contact_procs.OnContactAdded   = jolt_on_contact_added;
  g_contact_procs.OnContactRemoved = jolt_on_contact_removed;
  JPH_ContactListener_SetProcs(&g_contact_procs);

  struct RClass *m = mrb_define_module(mrb, "Jolt");

  /* motion type constants */
  mrb_define_const(mrb, m, "STATIC",    mrb_int_value(mrb, JPH_MotionType_Static));
  mrb_define_const(mrb, m, "KINEMATIC", mrb_int_value(mrb, JPH_MotionType_Kinematic));
  mrb_define_const(mrb, m, "DYNAMIC",   mrb_int_value(mrb, JPH_MotionType_Dynamic));

  /* shape factories (module functions) */
  mrb_define_module_function(mrb, m, "_box",         jolt_box,         MRB_ARGS_REQ(3));
  mrb_define_module_function(mrb, m, "_sphere",      jolt_sphere,      MRB_ARGS_REQ(1));
  mrb_define_module_function(mrb, m, "_capsule",     jolt_capsule,     MRB_ARGS_REQ(2));
  mrb_define_module_function(mrb, m, "_cylinder",    jolt_cylinder,    MRB_ARGS_REQ(2));
  mrb_define_module_function(mrb, m, "_convex_hull", jolt_convex_hull, MRB_ARGS_REQ(1));
  mrb_define_module_function(mrb, m, "_mesh",        jolt_mesh,        MRB_ARGS_REQ(1));

  struct RClass *shape = mrb_define_class_under(mrb, m, "Shape", mrb->object_class);
  MRB_SET_INSTANCE_TT(shape, MRB_TT_DATA);

  struct RClass *world = mrb_define_class_under(mrb, m, "World", mrb->object_class);
  MRB_SET_INSTANCE_TT(world, MRB_TT_DATA);
  mrb_define_method(mrb, world, "_setup", jolt_world_init, MRB_ARGS_REQ(4));
  mrb_define_method(mrb, world, "_step",      jolt_step,       MRB_ARGS_REQ(2));
  mrb_define_method(mrb, world, "_optimize",  jolt_optimize,   MRB_ARGS_NONE());
  mrb_define_method(mrb, world, "_set_gravity", jolt_set_gravity, MRB_ARGS_REQ(3));
  mrb_define_method(mrb, world, "_add_body",  jolt_add_body,   MRB_ARGS_REQ(12));
  mrb_define_method(mrb, world, "_remove_body", jolt_remove_body, MRB_ARGS_REQ(1));
  mrb_define_method(mrb, world, "_position",  jolt_position,   MRB_ARGS_REQ(1));
  mrb_define_method(mrb, world, "_com_position", jolt_com_position, MRB_ARGS_REQ(1));
  mrb_define_method(mrb, world, "_rotation",  jolt_rotation,   MRB_ARGS_REQ(1));
  mrb_define_method(mrb, world, "_set_transform", jolt_set_transform, MRB_ARGS_REQ(9));
  mrb_define_method(mrb, world, "_linear_velocity", jolt_linear_velocity, MRB_ARGS_REQ(1));
  mrb_define_method(mrb, world, "_set_linear_velocity", jolt_set_linear_velocity, MRB_ARGS_REQ(4));
  mrb_define_method(mrb, world, "_angular_velocity", jolt_angular_velocity, MRB_ARGS_REQ(1));
  mrb_define_method(mrb, world, "_set_angular_velocity", jolt_set_angular_velocity, MRB_ARGS_REQ(4));
  mrb_define_method(mrb, world, "_add_force",   jolt_add_force,   MRB_ARGS_REQ(4));
  mrb_define_method(mrb, world, "_add_impulse", jolt_add_impulse, MRB_ARGS_REQ(4));
  mrb_define_method(mrb, world, "_add_torque",  jolt_add_torque,  MRB_ARGS_REQ(4));
  mrb_define_method(mrb, world, "_active?",   jolt_is_active,  MRB_ARGS_REQ(1));
  mrb_define_method(mrb, world, "_activate",  jolt_activate,   MRB_ARGS_REQ(1));
  mrb_define_method(mrb, world, "_deactivate", jolt_deactivate, MRB_ARGS_REQ(1));
  mrb_define_method(mrb, world, "_raycast",   jolt_raycast,    MRB_ARGS_REQ(6));
  mrb_define_method(mrb, world, "_contacts",  jolt_contacts,   MRB_ARGS_NONE());
  mrb_define_method(mrb, world, "_contacts_ended", jolt_contacts_ended, MRB_ARGS_NONE());
  mrb_define_method(mrb, world, "_overlap_point",  jolt_overlap_point,  MRB_ARGS_REQ(3));
  mrb_define_method(mrb, world, "_set_sensor", jolt_set_sensor, MRB_ARGS_REQ(2));
  mrb_define_method(mrb, world, "_set_ccd",    jolt_set_ccd,    MRB_ARGS_REQ(2));
  mrb_define_method(mrb, world, "_fixed",    jolt_c_fixed,    MRB_ARGS_REQ(2));
  mrb_define_method(mrb, world, "_point",    jolt_c_point,    MRB_ARGS_REQ(5));
  mrb_define_method(mrb, world, "_distance", jolt_c_distance, MRB_ARGS_REQ(10));
  mrb_define_method(mrb, world, "_hinge",    jolt_c_hinge,    MRB_ARGS_REQ(10));
  mrb_define_method(mrb, world, "_slider",   jolt_c_slider,   MRB_ARGS_REQ(10));
  mrb_define_method(mrb, world, "_cone",     jolt_c_cone,     MRB_ARGS_REQ(9));
  mrb_define_method(mrb, world, "_user_data",      jolt_user_data,       MRB_ARGS_REQ(1));
  mrb_define_method(mrb, world, "_set_user_data",  jolt_set_user_data,   MRB_ARGS_REQ(2));
  mrb_define_method(mrb, world, "_motion_type",     jolt_motion_type,     MRB_ARGS_REQ(1));
  mrb_define_method(mrb, world, "_set_motion_type", jolt_set_motion_type, MRB_ARGS_REQ(3));
  mrb_define_method(mrb, world, "_friction",       jolt_friction,        MRB_ARGS_REQ(1));
  mrb_define_method(mrb, world, "_set_friction",   jolt_set_friction,    MRB_ARGS_REQ(2));
  mrb_define_method(mrb, world, "_restitution",     jolt_restitution,     MRB_ARGS_REQ(1));
  mrb_define_method(mrb, world, "_set_restitution", jolt_set_restitution, MRB_ARGS_REQ(2));
  mrb_define_method(mrb, world, "_gravity_factor",     jolt_gravity_factor,     MRB_ARGS_REQ(1));
  mrb_define_method(mrb, world, "_set_gravity_factor", jolt_set_gravity_factor, MRB_ARGS_REQ(2));
  mrb_define_method(mrb, world, "_character", jolt_world_character, MRB_ARGS_REQ(6));
  mrb_define_method(mrb, world, "_ragdoll",   jolt_world_ragdoll,   MRB_ARGS_REQ(2));

  struct RClass *con = mrb_define_class_under(mrb, m, "Constraint", mrb->object_class);
  MRB_SET_INSTANCE_TT(con, MRB_TT_DATA);
  mrb_define_method(mrb, con, "_remove", jolt_constraint_remove, MRB_ARGS_NONE());

  struct RClass *rag = mrb_define_class_under(mrb, m, "Ragdoll", mrb->object_class);
  MRB_SET_INSTANCE_TT(rag, MRB_TT_DATA);
  mrb_define_method(mrb, rag, "_body_count", jolt_ragdoll_body_count, MRB_ARGS_NONE());
  mrb_define_method(mrb, rag, "_body_id",    jolt_ragdoll_body_id,    MRB_ARGS_REQ(1));
  mrb_define_method(mrb, rag, "_activate",   jolt_ragdoll_activate,   MRB_ARGS_NONE());
  mrb_define_method(mrb, rag, "_remove",     jolt_ragdoll_remove,     MRB_ARGS_NONE());

  struct RClass *chr = mrb_define_class_under(mrb, m, "Character", mrb->object_class);
  MRB_SET_INSTANCE_TT(chr, MRB_TT_DATA);
  mrb_define_method(mrb, chr, "_update",        jolt_char_update,       MRB_ARGS_REQ(1));
  mrb_define_method(mrb, chr, "_position",      jolt_char_position,     MRB_ARGS_NONE());
  mrb_define_method(mrb, chr, "_set_position",  jolt_char_set_position, MRB_ARGS_REQ(3));
  mrb_define_method(mrb, chr, "_velocity",      jolt_char_velocity,     MRB_ARGS_NONE());
  mrb_define_method(mrb, chr, "_set_velocity",  jolt_char_set_velocity, MRB_ARGS_REQ(3));
  mrb_define_method(mrb, chr, "_ground_state",  jolt_char_ground_state, MRB_ARGS_NONE());
  mrb_define_method(mrb, chr, "_ground_normal", jolt_char_ground_normal, MRB_ARGS_NONE());
  mrb_define_method(mrb, chr, "_supported?",    jolt_char_supported,    MRB_ARGS_NONE());
  mrb_define_method(mrb, chr, "_ground_velocity", jolt_char_ground_velocity, MRB_ARGS_NONE());
  mrb_define_method(mrb, chr, "_ground_body_id",  jolt_char_ground_body_id,  MRB_ARGS_NONE());
  mrb_define_method(mrb, chr, "_max_strength",     jolt_char_max_strength,     MRB_ARGS_NONE());
  mrb_define_method(mrb, chr, "_set_max_strength", jolt_char_set_max_strength, MRB_ARGS_REQ(1));
  mrb_define_method(mrb, chr, "_set_mass",         jolt_char_set_mass,         MRB_ARGS_REQ(1));
}

void mrb_jolt_gem_final(mrb_state *mrb) { (void)mrb; JPH_Shutdown(); }

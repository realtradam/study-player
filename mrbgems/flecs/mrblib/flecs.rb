# Idiomatic Ruby surface for flecs, layered on the low-level Flecs::World#_*
# primitives (see src/flecs_bindings.c). Components are declared at runtime via
# the meta addon and (de)serialized to/from Ruby Hashes.
#
#   world = Flecs::World.new
#   pos   = world.struct("Position", "{float x; float y;}")
#   vel   = world.struct("Velocity", "{float x; float y;}")
#   e = world.entity("player").set(pos, x: 0, y: 0).set(vel, x: 1, y: 2)
#
#   world.system("Move", with: [pos, vel]) do |id, p, v|
#     p[:x] += v[:x]; p[:y] += v[:y]      # mutations to p are written back
#   end
#   world.progress(1.0/60)

module Flecs
  class World
    # Create an entity (optionally named). Returns a Flecs::Entity.
    def entity(name = nil)
      Entity.new(self, _entity(name && name.to_s))
    end

    # Declare a component as a C struct from a meta descriptor string, e.g.
    #   world.struct("Position", "{float x; float y;}")
    # Returns a Flecs::Component (usable wherever an id is expected).
    def struct(name, descriptor)
      Component.new(self, _struct(name.to_s, descriptor))
    end
    alias component struct

    # A tag is a dataless entity used as an id (add/remove/has).
    def tag(name)
      Component.new(self, _entity(name.to_s))
    end

    # Look up an entity/component by name -> Flecs::Entity | nil.
    def lookup(name)
      id = _lookup(name.to_s)
      id && Entity.new(self, id)
    end

    # Wrap a raw entity id (e.g. one yielded to a system/query block) in a
    # Flecs::Entity so you can call set/get/add/... on it.
    def entity_for(id)
      Entity.new(self, id.to_i)
    end

    # Cached query over the given component/tag ids -> Flecs::Query.
    def query(*components)
      _query(components.flatten.map(&:to_i))
    end

    # Register a system that runs each progress() during `phase`.
    # Block receives |entity_id, *component_hashes| per matched entity;
    # mutations to the component hashes are written back.
    def system(name, with:, phase: Flecs::ON_UPDATE, &block)
      _system(name.to_s, phase.to_i, Array(with).map(&:to_i), &block)
    end

    # Advance the world by dt seconds, running all systems. Returns false when
    # the world wants to quit.
    def progress(dt = 0.0)
      _progress(dt)
    end

    # Observability (R5): start the flecs REST API so the hosted Flecs Explorer
    # (flecs.dev/explorer?host=localhost:<port>) can inspect the live world.
    # Served during progress. Dev-only (opens a local port).
    def enable_rest(port = 27750)
      _enable_rest(port.to_i); self
    end

    # Per-system timing + world monitor stats (shown in the Explorer).
    def enable_stats
      _enable_stats; self
    end

    # Query the flecs REST API in-process (no socket — works on desktop AND web).
    # Requires enable_rest first. Returns raw JSON string.
    #   world.rest_request("GET", "/world")
    #   world.rest_request("GET", "/query?expr=Position&values=true")
    def rest_request(method, path, body = "")
      _rest_request(method.to_s, path.to_s, body.to_s)
    end
  end

  # Lightweight wrapper around an entity id bound to its world.
  class Entity
    attr_reader :id, :world
    def initialize(world, id); @world = world; @id = id; end
    def to_i; @id; end
    def to_int; @id; end

    def name;      @world._name(@id); end
    def name=(n);  @world._set_name(@id, n.to_s); end
    def delete;    @world._delete(@id); end
    def alive?;    @world._alive?(@id); end

    # set(comp, x: 1, y: 2) or set(comp, {x: 1, y: 2})
    def set(comp, fields = nil, **kw)
      @world._set(@id, comp.to_i, fields || kw); self
    end
    def get(comp);    @world._get(@id, comp.to_i); end   # -> Hash | nil
    def add(comp);    @world._add(@id, comp.to_i); self; end
    def remove(comp); @world._remove(@id, comp.to_i); self; end
    def has?(comp);   @world._has?(@id, comp.to_i); end

    def ==(other); other.respond_to?(:to_i) && other.to_i == @id; end
    def inspect; "#<Flecs::Entity #{@id}#{name ? " #{name.inspect}" : ''}>"; end
  end

  # Wrapper around a component/tag id (also just an entity under the hood).
  class Component
    attr_reader :id, :world
    def initialize(world, id); @world = world; @id = id; end
    def to_i; @id; end
    def to_int; @id; end
    def name; @world._name(@id); end
    def inspect; "#<Flecs::Component #{@id} #{name.inspect}>"; end
  end

  class Query
    include Enumerable
    # each { |entity_id, *component_hashes| ... } ; mutations written back.
    def each(&block); _each(&block); self; end
  end
end

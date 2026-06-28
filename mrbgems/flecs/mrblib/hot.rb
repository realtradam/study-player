# Flecs::Hot (R3): hot-reloadable systems. Register a system ONCE with a stable
# dispatcher block that looks up the current proc by name; on reload just replace
# the proc in the registry — same system id, same matched tables, same entity and
# component data, new logic. No C change to the flecs binding (it bakes the block
# into callback_ctx; we hand it a dispatcher). See .agents/knowledge/hot-reload.md.
#
#   world = Flecs::World.new
#   world.struct("Position", "{float x; float y;}")
#   world.struct("Velocity", "{float x; float y;}")
#   Flecs::Hot.world = world
#   Flecs::Hot.define_system("Move", with: ["Position", "Velocity"]) do |e, p, v|
#     p[:x] += v[:x]; p[:y] += v[:y]
#   end
#   world.progress(1.0/60)
#   # ...edit + reload (over the bridge or from a file): swaps the proc, keeps state
#   Flecs::Hot.reload_string('Flecs::Hot.define_system("Move", with: ["Position","Velocity"]){|e,p,v| p[:x]+=v[:x]*5 }')
module Flecs
  module Hot
    @world   = nil
    @systems = {}   # name(String) => { id:, with:, phase:, proc: }

    class << self
      attr_accessor :world

      # Register (first call) or hot-swap (reload) a system. Idempotent: re-running
      # a systems file just replaces procs.
      def define_system(name, with:, phase: Flecs::ON_UPDATE, &blk)
        raise "Flecs::Hot.world not set" unless @world
        raise ArgumentError, "define_system requires a block" unless blk
        name  = name.to_s
        terms = Array(with)
        cur   = @systems[name]

        # Hot path: same shape -> swap the proc only (id/tables/state preserved).
        if cur && cur[:with] == terms && cur[:phase] == phase
          cur[:proc] = blk
          Jamstack::Log.info("system swap", tag: "hot", system: name, id: cur[:id])
          return cur[:id]
        end

        # Shape changed (or first time): (re-)register. Deleting the old system
        # entity does NOT touch entity/component data.
        @world.entity_for(cur[:id]).delete if cur

        rec = { with: terms, phase: phase, proc: blk }
        @systems[name] = rec   # set before register: the dispatcher reads it live
        rec[:id] = @world.system(name, with: terms.map { |t| resolve(t) }, phase: phase) do |eid, *comps|
          s = @systems[name]
          s[:proc].call(eid, *comps) if s && s[:proc]
        end
        Jamstack::Log.info(cur ? "system reregister" : "system register",
                           tag: "hot", system: name, id: rec[:id])
        rec[:id]
      end

      # Re-eval a chunk of systems Ruby (from the bridge). Never raises.
      def reload_string(code)
        eval(code)
        true
      rescue Exception => e
        Jamstack::Log.exception(e, tag: "hot")
        false
      end

      # Re-eval a systems file (the reloadable unit).
      def reload_file(path)
        reload_string(File.read(path))
      rescue Exception => e
        Jamstack::Log.exception(e, tag: "hot", path: path.to_s)
        false
      end

      def id_for(name); (s = @systems[name.to_s]) && s[:id]; end
      def systems; @systems.keys; end
      def reset!;  @systems = {}; end   # forget registrations (does not delete systems)

      private

      # Accept component ids (Component/Integer) or string names (looked up live, so
      # reload need not re-create components).
      def resolve(t)
        return t.to_i unless t.is_a?(String)
        c = @world.lookup(t)
        raise ArgumentError, "unknown component #{t.inspect}" unless c
        c.to_i
      end
    end
  end
end

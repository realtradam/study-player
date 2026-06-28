# Study Player — layout map and defaults (Phase 2 stub; Phase 6 implements).
#
# See: notes/study-player-rewrite-plan.md §9 (layout persistence)

module StudyPlayer
  module Layout
    def self.defaults
      {}
    end

    def self.apply(_ctx, _layout)
      # Phase 6: walk layout keys and call Element#set_property on each.
    end
  end
end

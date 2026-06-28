# Study Player — layout config persistence (Phase 2 stub; Phase 6 implements).
#
# See: notes/study-player-rewrite-plan.md §9 (layout persistence)

module StudyPlayer
  module Config
    CFG_FILE = "study-player.cfg".freeze

    def self.load
      {}
    end

    def self.save(_layout)
      true
    end
  end
end

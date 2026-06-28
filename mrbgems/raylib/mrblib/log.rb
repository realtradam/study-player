# Jamstack structured logging (R2): leveled, structured (NDJSON) records with a
# monotonic frame counter, an in-memory ring buffer the agent can query over the
# bridge (Log.tail / Log.grep), and stdout + optional file sinks. This is the
# "game-console" stream (Ruby/engine intent). The browser-console (web platform
# console) is deferred (see roadmap R2/R4).
#
# Usage:
#   Jamstack::Log.info("spawned", tag: "spawn", entity: id)
#   Jamstack::Log.error("bad state", entity: id)
#   Jamstack::Log.exception(e, tag: "physics")
#   Jamstack::Log.tail(50)            # last N records (Array of Hashes)
#   Jamstack::Log.grep("physics")     # substring match (no Regexp in this gembox)
#   Jamstack::Log.tail_ndjson(50)     # last N as an NDJSON string (for the agent)
#
# Env (read at setup, via Jamstack.getenv): JAMSTACK_LOG=<path> (file sink),
# JAMSTACK_LOG_LEVEL=debug|info|warn|error (min level).
module Jamstack
  module Log
    LEVELS = { debug: 0, info: 1, warn: 2, error: 3 }

    @level     = :debug
    @frame     = 0
    @ring      = []
    @ring_max  = 1000
    @to_stdout = true
    @file      = nil
    @setup_done = false

    class << self
      attr_accessor :ring_max, :to_stdout
      attr_reader   :level, :frame

      def level=(sym)
        @level = sym.to_sym if LEVELS.key?(sym.to_sym)
      end

      def setup
        return if @setup_done
        @setup_done = true
        lvl = Jamstack.getenv('JAMSTACK_LOG_LEVEL')
        self.level = lvl if lvl && !lvl.empty?
        path = Jamstack.getenv('JAMSTACK_LOG')
        open_file(path) if path && !path.empty?
      end

      def open_file(path)
        @file = File.open(path, 'a')
      rescue StandardError
        @file = nil
      end

      def tick!; @frame += 1; end

      def log(level, msg = nil, fields = {})
        return nil if LEVELS[level].to_i < LEVELS[@level].to_i
        rec = build(level, msg, fields)
        sink(Jamstack::JSON.generate(rec))   # render BEFORE pushing (cheap, ordered)
        push(rec)
        rec
      end

      def debug(msg = nil, fields = {}); log(:debug, msg, fields); end
      def info(msg = nil, fields = {});  log(:info,  msg, fields); end
      def warn(msg = nil, fields = {});  log(:warn,  msg, fields); end
      def error(msg = nil, fields = {}); log(:error, msg, fields); end

      # Capture an exception as an error record with class + backtrace.
      def exception(e, fields = {})
        f = { error: "#{e.class}: #{e.message}", backtrace: (e.backtrace || []) }
        f.merge!(fields)
        log(:error, e.message, f)
      end

      # --- agent query surface (read the ring without a file) ---
      def tail(n = 50); @ring.last(n); end

      def grep(substr, n = 200)
        s = substr.to_s
        @ring.select { |r| Jamstack::JSON.generate(r).include?(s) }.last(n)
      end

      def tail_ndjson(n = 50)
        tail(n).map { |r| Jamstack::JSON.generate(r) }.join("\n")
      end

      def clear!; @ring = []; end

      private

      def build(level, msg, fields)
        rec = {}
        rec["ts"]    = now
        rec["frame"] = @frame
        rec["level"] = level.to_s
        rec["msg"]   = msg.to_s unless msg.nil?
        fields.each { |k, v| rec[k.to_s] = v }
        rec
      end

      def now
        Time.now.to_f
      rescue StandardError
        0.0
      end

      def push(rec)
        @ring << rec
        @ring.shift while @ring.length > @ring_max
      end

      # NOTE: stdout writes to C fd 1. If a log is emitted *during* a bridge eval
      # (while fd 1 is redirected for stdout capture), the line lands in that
      # eval's captured stdout instead of the console — the ring buffer still
      # records it, which is the canonical query path. See agent-bridge.md.
      def sink(line)
        puts line if @to_stdout
        if @file
          @file.write(line)
          @file.write("\n")
          @file.flush
        end
      end
    end
  end
end

# Jamstack::Live (R4, desktop slice): a read-mostly .live/<token>/ file mount the
# game writes itself — no relay, no WS. A file-based agent drops raw-Ruby command
# files and reads JSON results; status + the game-console are written for tailing.
# Drained in-frame on the main thread (P6), reusing Bridge.eval_code (R1).
# Gate: JAMSTACK_BRIDGE=1. Token: JAMSTACK_LIVE (default "dev"), root:
# JAMSTACK_LIVE_ROOT (default ".live"). See .agents/knowledge/live-mount.md.
#
# Protocol (no JSON parser in mruby): cmd files carry RAW Ruby, id is the filename;
# only results are JSON.
#   .live/dev/.agent/cmd-<id>.rb   (agent writes; atomic: .tmp then rename)
#   .live/dev/.agent/result-<id>.json  (game writes {id,ok,result,stdout,error,backtrace})
module Jamstack
  module Live
    STATUS_EVERY = 30   # frames between status.json rewrites (~0.5s @ 60fps)

    EVAL_SH = [
      '#!/bin/sh',
      '# Run Ruby in the live game; prints the JSON result envelope.',
      '# usage: sh bin/eval "Rl.get_fps"',
      'ag="$(cd "$(dirname "$0")/.." && pwd)/.agent"',
      'id="p$$_$(date +%s%N 2>/dev/null || date +%s)"',
      'printf "%s" "$1" > "$ag/.tmp-$id"',
      'mv "$ag/.tmp-$id" "$ag/cmd-$id.rb"',
      'i=0',
      'while [ $i -lt 250 ]; do',
      '  if [ -f "$ag/result-$id.json" ]; then',
      '    cat "$ag/result-$id.json"; echo; rm -f "$ag/result-$id.json"; exit 0',
      '  fi',
      '  i=$((i + 1)); sleep 0.02',
      'done',
      'echo "{\"ok\":false,\"error\":\"timeout waiting for result\"}" >&2; exit 1',
    ].join("\n") + "\n"

    TAIL_SH = [
      '#!/bin/sh',
      '# Stream the game-console (NDJSON). usage: sh bin/tail-log [N]',
      'd="$(cd "$(dirname "$0")/.." && pwd)"',
      'exec tail -n "${1:-40}" -f "$d/game-console"',
    ].join("\n") + "\n"

    HOT_SH = [
      '#!/bin/sh',
      '# Hot-reload a systems file. usage: sh bin/hot-reload game/systems/move.rb',
      'exec "$(dirname "$0")/eval" "Flecs::Hot.reload_file(\"$1\")"',
    ].join("\n") + "\n"

    SNAP_SH = [
      '#!/bin/sh',
      '# Dump the flecs world state to state.json and print the JSON.',
      '# usage: sh bin/snapshot   (requires $flecs.enable_rest in game code)',
      'exec "$(dirname "$0")/eval" \'Jamstack::Live.snapshot\'',
    ].join("\n") + "\n"

    QUERY_SH = [
      '#!/bin/sh',
      '# Query the flecs world. usage: sh bin/query Position',
      '# (requires $flecs.enable_rest in game code; expr is a flecs query expr)',
      'exec "$(dirname "$0")/eval" "Flecs::Hot.world.rest_request(\"GET\",\"/query?expr=$1&values=true\",\"\")"',
    ].join("\n") + "\n"

    @active   = false
    @dir      = nil
    @agent    = nil
    @throttle = 0

    class << self
      def active?; @active; end
      def dir; @dir; end

      def start
        return if @active
        token  = nonempty(Jamstack.getenv('JAMSTACK_LIVE'), 'dev')
        root   = nonempty(Jamstack.getenv('JAMSTACK_LIVE_ROOT'), '.live')
        @dir   = File.join(root, token)
        @agent = File.join(@dir, '.agent')
        mkdir_p(@agent)
        mkdir_p(File.join(@dir, 'bin'))
        clean_agent
        write_bin_scripts
        Jamstack::Log.open_file(File.join(@dir, 'game-console'))
        @active = true
        write_status
        Jamstack::Log.info("live mount ready", tag: "live", dir: @dir)
      rescue Exception => e
        @active = false
        Jamstack::Log.exception(e, tag: "live")
      end

      # Per frame, after Bridge.drain: run any queued command files, refresh status.
      def poll
        return unless @active
        process_commands
        @throttle += 1
        if @throttle >= STATUS_EVERY
          @throttle = 0
          write_status
        end
      end

      # Dump the flecs world state to state.json (called by bin/snapshot).
      # Uses the flecs REST API in-process (requires enable_rest on the world).
      def snapshot
        world = Flecs::Hot.world
        return nil unless world
        json = world.rest_request("GET", "/world", "")
        write_state(json)
        json
      rescue Exception => e
        Jamstack::Log.exception(e, tag: "live")
        nil
      end

      private

      def nonempty(v, default); (v && !v.empty?) ? v : default; end
      def now; Time.now.to_f; rescue StandardError; 0.0; end

      def process_commands
        entries = (Dir.entries(@agent) rescue [])
        entries.select { |f| f.start_with?("cmd-") }.sort.each do |f|
          id = f[4..-1]                       # after "cmd-"
          id = id[0...-3] if id.end_with?(".rb")
          path = File.join(@agent, f)
          code = (File.read(path) rescue nil)
          delete(path)                        # consume once
          next if code.nil?
          env = Jamstack::Bridge.eval_code(code)
          write_atomic(File.join(@agent, "result-#{id}.json"),
            Jamstack::JSON.generate(
              "id" => id, "ok" => env[:ok], "result" => env[:result],
              "stdout" => env[:stdout], "error" => env[:error],
              "backtrace" => env[:backtrace]))
        end
      end

      def write_status
        write_atomic(File.join(@dir, 'status.json'),
          Jamstack::JSON.generate(
            "connected" => true,
            "target"    => (Rl.web? ? "web" : "desktop"),
            "token"     => File.basename(@dir),
            "frame"     => Jamstack::Log.frame,
            "fps"       => (Rl.get_fps rescue 0),
            "ts"        => now))
      end

      def write_state(json)
        write_atomic(File.join(@dir, 'state.json'), json)
      end

      def write_bin_scripts
        bin = File.join(@dir, 'bin')
        { 'eval' => EVAL_SH, 'tail-log' => TAIL_SH, 'hot-reload' => HOT_SH,
          'snapshot' => SNAP_SH, 'query' => QUERY_SH }.each do |name, body|
          p = File.join(bin, name)
          File.open(p, 'w') { |fh| fh.write(body) }
          (File.chmod(0755, p) rescue nil)
        end
      end

      def clean_agent
        (Dir.entries(@agent) rescue []).each do |f|
          next if f == "." || f == ".."
          delete(File.join(@agent, f)) if f.start_with?("cmd-") || f.start_with?("result-") || f.start_with?(".tmp")
        end
      end

      # recursive mkdir (mruby has no mkdir -p)
      def mkdir_p(path)
        acc = path.start_with?("/") ? "" : nil
        path.split("/").each do |part|
          next if part.empty?
          acc = acc.nil? ? part : "#{acc}/#{part}"
          (Dir.mkdir(acc) unless File.directory?(acc)) rescue nil
        end
      end

      def write_atomic(path, str)
        tmp = "#{path}.tmp"
        File.open(tmp, 'w') { |fh| fh.write(str) }
        File.rename(tmp, path)
      rescue Exception => e
        Jamstack::Log.exception(e, tag: "live", path: path.to_s) rescue nil
      end

      def delete(path)
        File.delete(path)
      rescue StandardError
        (File.unlink(path) rescue nil)
      end
    end
  end
end

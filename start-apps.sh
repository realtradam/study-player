#!/bin/bash
mkdir -p /run/user/$(id -u)

# Launch study-player.
# The script path is REQUIRED: with no arg, main.c defaults to game/main.rb
# (the raylib-jamstack HUD demo), which has no file-drop handler. The study
# player — whose CheckFileDrop system (drag-and-drop) lives here — must be
# loaded explicitly. Drag-and-drop otherwise silently does nothing.
cd /home/tradam/projects/study-player/rewrite
DISPLAY=:0 XDG_RUNTIME_DIR=/run/user/$(id -u) ./zig-out/bin/game game/study_player/study_player.rb &
SPID=$!

# Launch pcmanfm
DISPLAY=:0 XDG_RUNTIME_DIR=/run/user/$(id -u) pcmanfm &
PCPID=$!

echo "study-player PID: $SPID"
echo "pcmanfm PID: $PCPID"

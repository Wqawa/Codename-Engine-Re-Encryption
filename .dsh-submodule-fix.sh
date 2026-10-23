#!/usr/bin/env bash
# Sequentially init lime submodules (Steam++/Watt Toolkit MITM stalls on parallel clones)
cd "D:/FNF/FNF code/Codename-Engine_Re-Encryption/.haxelib/lime/git" || exit 1
GIT="/c/Program Files/Git/cmd/git.exe"
export GIT_TERMINAL_PROMPT=0
for m in pixman png sdl vorbis vpx webm; do
  echo "=== $(date +%H:%M:%S) start $m ==="
  timeout 900 "$GIT" submodule update --init --depth 1 "project/lib/$m" 2>&1 | tail -3
  echo "=== $(date +%H:%M:%S) done $m rc=$? ==="
done
echo "=== ALL DONE $(date +%H:%M:%S) ==="

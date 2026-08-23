#!/bin/sh
# Both bit-op paths must produce identical galaxies, or the Nakama server and
# the Defold client would disagree about what a seed means.
#
# Defold uses LuaJIT's BitOp; Nakama's runtime is gopher-lua, which has none and
# takes the arithmetic path in galaxy/rng.lua.
set -e
cd "$(dirname "$0")/.."

luajit tools/verify_determinism.lua 1 | grep '^seed' > /tmp/galaxy_bitop.txt
GALAXY_PURE_BITOPS=1 luajit tools/verify_determinism.lua 1 | grep '^seed' > /tmp/galaxy_pure.txt

if diff -q /tmp/galaxy_bitop.txt /tmp/galaxy_pure.txt > /dev/null; then
  cat /tmp/galaxy_bitop.txt
  echo "OK: BitOp and arithmetic bit-op paths agree"
else
  echo "MISMATCH between bit-op implementations:"
  diff /tmp/galaxy_bitop.txt /tmp/galaxy_pure.txt || true
  exit 1
fi

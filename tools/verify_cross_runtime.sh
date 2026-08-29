#!/bin/sh
# Both bit-op paths must produce identical realms, or the Nakama server and
# the Defold client would disagree about what a seed means.
#
# Defold uses LuaJIT's BitOp; Nakama's runtime is gopher-lua, which has none and
# takes the arithmetic path in realm/rng.lua.
set -e
cd "$(dirname "$0")/.."

luajit tools/verify_determinism.lua 1 | grep '^seed' > /tmp/realm_bitop.txt
REALM_PURE_BITOPS=1 luajit tools/verify_determinism.lua 1 | grep '^seed' > /tmp/realm_pure.txt

if diff -q /tmp/realm_bitop.txt /tmp/realm_pure.txt > /dev/null; then
  cat /tmp/realm_bitop.txt
  echo "OK: BitOp and arithmetic bit-op paths agree"
else
  echo "MISMATCH between bit-op implementations:"
  diff /tmp/realm_bitop.txt /tmp/realm_pure.txt || true
  exit 1
fi

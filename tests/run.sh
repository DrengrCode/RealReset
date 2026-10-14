#!/usr/bin/env bash
# Runs the Java tests against fake game classes (no game needed), and the Lua mock runs if a `lua` binary exists.
set -euo pipefail
cd "$(dirname "$0")/.."
./build.sh >/dev/null
T=$(mktemp -d); mkdir -p "$T/home/Saves/Multiplayer/Broc/map/10" "$T/cls"
javac -d "$T/cls" $(find tests/fake -name '*.java') src/com/drengrcode/realreset/RealReset.java -cp build/stubcls
javac -cp "$T/cls" -d "$T/cls" tests/RestoreTest.java
java -Dfake.cache="$T/home" -cp "$T/cls:build/stubcls" RestoreTest | grep -E 'FAIL|ALL PASS'
if command -v lua >/dev/null; then
  M=Contents/mods/RealReset/42/media/lua
  lua tests/lua/server_mock.lua $M/server/RealReset_Server.lua | grep -v '^\[RealReset\]' | head -3
  lua tests/lua/claims_warn_mock.lua $M/server/RealReset_Server.lua | grep -E 'FAIL|ALL PASS'
  lua tests/lua/client_mock.lua $M/client/RealReset_Client.lua | head -5
fi
rm -rf "$T"

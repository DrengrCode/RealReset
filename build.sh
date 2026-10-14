#!/usr/bin/env bash
# Builds media/java/RealReset.jar and a release zip. Needs a JDK (17+). No game files needed.
set -euo pipefail
cd "$(dirname "$0")"
VER=$(grep -o 'VERSION = "[^"]*"' src/com/drengrcode/realreset/RealReset.java | cut -d'"' -f2)
rm -rf build Contents/mods/RealReset/42/media/java && mkdir -p build/stubcls build/classes Contents/mods/RealReset/42/media/java
javac -d build/stubcls stubs/se/krka/kahlua/integration/annotations/LuaMethod.java
javac --release 17 -Xlint:all -cp build/stubcls -d build/classes src/com/drengrcode/realreset/RealReset.java
# the jar contains ONLY our classes (the annotation stub is compile-time only)
jar cf Contents/mods/RealReset/42/media/java/RealReset.jar -C build/classes .
rm -f "RealReset_v${VER}.zip"
( cd Contents/mods && zip -qr "../../RealReset_v${VER}.zip" RealReset )
echo "built RealReset_v${VER}.zip"

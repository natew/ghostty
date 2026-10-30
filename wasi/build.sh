#!/usr/bin/env bash
# builds libghostty-internal-fat.a for wasm32-wasi (peach). run from the fork root after `zig build --fetch`.
# libxev's own build.zig returns UnsupportedPlatform for its examples on wasi; zig has no dependency
# patching, so the fetched copy is edited in place.
set -e
cd "$(dirname "$0")/.."
for f in zig-pkg/libxev-*/build.zig; do
  perl -pi -e 's/^    const examples = try buildExamples\(b, target, optimize, static_lib\);/    const examples: []const *Step.Compile = if (target.result.os.tag == .wasi) &.{} else try buildExamples(b, target, optimize, static_lib);/' "$f"
done
exec zig build -Dtarget=wasm32-wasi -Dcpu=generic+exception_handling -Dapp-runtime=none \
  -Dfont-backend=freetype -Drenderer=opengl -Dsentry=false -Demit-exe=false -Demit-docs=false \
  -Demit-webdata=false -Demit-helpgen=false -Demit-terminfo=false -Demit-termcap=false \
  -Demit-themes=false -Demit-xcframework=false -Doptimize=ReleaseSmall --summary failures "$@"

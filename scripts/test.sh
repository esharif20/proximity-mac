#!/bin/sh
# Runs `swift test` with any extra arguments (for example `--filter PresenceEngine`).
# Command Line Tools without Xcode ship Swift Testing outside the default search path and with a
# broken Foundation cross-import overlay, so on such machines add the path and turn overlays off.
set -eu
F=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
if [ "$(xcode-select -p)" = /Library/Developer/CommandLineTools ] && [ -d "$F/Testing.framework" ]; then
  exec swift test -Xswiftc -F"$F" -Xlinker -F"$F" -Xlinker -rpath -Xlinker "$F" \
    -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays "$@"
fi
exec swift test "$@"

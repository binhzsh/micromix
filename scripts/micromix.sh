#!/usr/bin/env bash
# Micromix helper CLI.
# Usage:
#   micromix rebuild   -> regenerate project, build Release app, launch it
#   micromix start     -> launch Release app (builds it first if missing)
#   micromix stop      -> terminate the running Micromix app
set -euo pipefail

# Resolve symlinks so the repo root is found even when invoked via ~/.local/bin.
SELF="${BASH_SOURCE[0]}"
while [ -L "$SELF" ]; do SELF="$(readlink "$SELF")"; done
REPO_ROOT="$(cd "$(dirname "$SELF")/.." && pwd)"
APP_DIR="$REPO_ROOT/MacOS"
APP_BUNDLE="$APP_DIR/build/Build/Products/Release/Micromix.app"
APP_NAME="Micromix"

die() { echo "micromix: $1" >&2; exit 1; }

build_release() {
  cd "$APP_DIR"
  echo "micromix: regenerating Xcode project..."
  xcodegen generate >/dev/null
  echo "micromix: building Release app..."
  xcodebuild -project Micromix.xcodeproj -scheme Micromix \
    -configuration Release -derivedDataPath build build
  echo "micromix: built $APP_BUNDLE"
}

start() {
  if [ ! -d "$APP_BUNDLE" ]; then
    echo "micromix: no Release build found; running rebuild first..."
    build_release
  fi
  open "$APP_BUNDLE"
  echo "micromix: launched $APP_NAME"
}

stop() {
  if pgrep -xq "$APP_NAME"; then
    pkill -x "$APP_NAME"
    echo "micromix: stopped $APP_NAME"
  else
    echo "micromix: $APP_NAME is not running"
  fi
}

case "${1:-}" in
  rebuild)
    build_release
    open "$APP_BUNDLE"
    echo "micromix: rebuilt and launched $APP_NAME"
    ;;
  start)
    start
    ;;
  stop)
    stop
    ;;
  *)
    die "unknown command '${1:-}'. Usage: micromix {rebuild|start|stop}"
    ;;
esac

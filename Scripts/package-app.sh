#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIGURATION="${CONFIGURATION:-Release}"
APP_DIR="${APP_DIR:-$ROOT_DIR/dist/Openola.app}"
INSTALL_APP="${INSTALL_APP:-0}"
INSTALL_DIR="${INSTALL_DIR:-/Applications/Openola.app}"
PROJECT_PATH="$ROOT_DIR/openola.xcodeproj"
SCHEME_NAME="${SCHEME_NAME:-openola}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$ROOT_DIR/.deriveddata}"
BUILT_APP_PATH="$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION/Openola.app"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

cd "$ROOT_DIR"
xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME_NAME" \
  -configuration "$CONFIGURATION" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  build

rm -rf "$APP_DIR"
mkdir -p "$(dirname "$APP_DIR")"
ditto "$BUILT_APP_PATH" "$APP_DIR"

if [[ "$INSTALL_APP" == "1" ]]; then
  rm -rf "$INSTALL_DIR"
  mkdir -p "$(dirname "$INSTALL_DIR")"
  ditto "$APP_DIR" "$INSTALL_DIR"
  echo "$INSTALL_DIR"
else
  echo "$APP_DIR"
fi

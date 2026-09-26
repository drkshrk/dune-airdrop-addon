#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$ROOT_DIR"

if ! command -v node >/dev/null 2>&1; then
  echo "node is required to validate addon.json." >&2
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 is required to package the addon." >&2
  exit 1
fi

node scripts/validate.js

ADDON_ID="$(node -e "process.stdout.write(require('./addon.json').id)")"
ADDON_VERSION="$(node -e "process.stdout.write(require('./addon.json').version)")"
PACKAGE_NAME="${ADDON_ID}-${ADDON_VERSION}.zip"

rm -rf dist
mkdir -p dist

python3 scripts/create_zip.py "dist/${PACKAGE_NAME}" \
  addon.json assets/dune_airdrop_art.png \
  web/addon.css web/addon.js web/dune-addon-bridge.js \
  web/grant_logic.js web/outbox_drain.js web/index.html web/style.css \
  setup_playtime_airdrops.sql uninstall_playtime_airdrops.sql README.md

echo "Created: dist/${PACKAGE_NAME}"

if command -v sha256sum >/dev/null 2>&1; then
  sha256sum "dist/${PACKAGE_NAME}" | tee "dist/${PACKAGE_NAME}.sha256"
elif command -v shasum >/dev/null 2>&1; then
  shasum -a 256 "dist/${PACKAGE_NAME}" | tee "dist/${PACKAGE_NAME}.sha256"
else
  echo "Install sha256sum or shasum to calculate the release hash." >&2
  exit 1
fi

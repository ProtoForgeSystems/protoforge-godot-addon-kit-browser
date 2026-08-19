#!/usr/bin/env bash
# Build the asset-store ZIP: tracked files wrapped under addons/kit_browser/,
# minus repo metadata the store guidelines prohibit.
set -euo pipefail
cd "$(dirname "$0")"
rm -rf build
mkdir -p build/addons/kit_browser
git ls-files | grep -v -e '^\.git' -e '^package\.sh$' | while read -r f; do
    mkdir -p "build/addons/kit_browser/$(dirname "$f")"
    cp "$f" "build/addons/kit_browser/$f"
done
(cd build && zip -qr kit_browser.zip addons)
echo "build/kit_browser.zip:"
unzip -l build/kit_browser.zip

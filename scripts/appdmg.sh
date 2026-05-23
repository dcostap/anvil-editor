#!/bin/bash
set -ex

if [ ! -e "src/api/api.h" ]; then
  echo "Please run this script from the root directory of Anvil."
  exit 1
fi

cat > anvil-dmg.json << EOF
{
  "title": "Anvil",
  "icon": "$(pwd)/resources/icons/icon.icns",
  "background": "$(pwd)/resources/macos/appdmg.png",
  "window": {
    "position": {
      "x": 360,
      "y": 360
    },
    "size": {
      "width": 480,
      "height": 360
    }
  },
  "contents": [
    { "x": 144, "y": 248, "type": "file", "path": "$(pwd)/Anvil.app" },
    { "x": 336, "y": 248, "type": "link", "path": "/Applications" }
  ]
}
EOF
~/node_modules/appdmg/bin/appdmg.js anvil-dmg.json "$(pwd)/$1.dmg"

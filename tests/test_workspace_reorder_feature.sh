#!/usr/bin/env bash
set -euo pipefail

qml_file="$(dirname "$0")/../MissionControl.qml"

grep -q 'function reorderDesktop' "$qml_file"
grep -q 'property var desktopOrder' "$qml_file"
grep -q 'orderedDesktops' "$qml_file"
grep -q 'DragHandler' "$qml_file"
grep -q 'reorderTarget' "$qml_file"
grep -q 'reorderEnd' "$qml_file"
grep -q 'reorderDropMarker' "$qml_file"
grep -q 'IpcHandler' "$qml_file"
grep -q 'previousWorkspace' "$qml_file"
grep -q 'nextWorkspace' "$qml_file"
grep -q 'if (root.activePanel)' "$qml_file"

echo "workspace reorder feature markers present"

#!/bin/bash

# Tests for ./setup against a throwaway HOME with stub hyprctl/omarchy
# commands. Run from the repository root: bash test/setup.sh

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

export HOME="$WORK/home"
mkdir -p "$HOME/.config/hypr" "$WORK/bin"

# Stub commands record how they were called.
for command in hyprctl omarchy omarchy-shell; do
  cat >"$WORK/bin/$command" <<STUB
#!/bin/bash
echo "$command \$*" >>"$WORK/calls"
STUB
  chmod +x "$WORK/bin/$command"
done
export PATH="$WORK/bin:$PATH"

CONFIG="$HOME/.config/hypr/hyprland.lua"
cat >"$CONFIG" <<'LUA'
dofile((os.getenv("OMARCHY_PATH") or "/usr/share/omarchy") .. "/default/hypr/bootstrap.lua")

-- Load Omarchy defaults.
require("default.hypr.omarchy")

-- Put your personal overrides in these files.
require("hypr.monitors")
require("hypr.bindings")
LUA
cp "$CONFIG" "$WORK/original.lua"

passed=0
failed=0

check() {
  local description=$1
  shift
  if "$@"; then
    echo "ok   $description"
    passed=$((passed + 1))
  else
    echo "FAIL $description"
    failed=$((failed + 1))
  fi
}

line_of() {
  grep -nF -- "$1" "$CONFIG" | head -1 | cut -d: -f1
}

"$ROOT/setup" install --yes >/dev/null

check "install adds the loader block once" \
  test "$(grep -cF -- '-- >>> gg.arkship.global-workspaces >>>' "$CONFIG")" -eq 1
check "the loader sits after Omarchy defaults and before personal bindings" \
  test "$(line_of 'require("default.hypr.omarchy")')" -lt "$(line_of '-- >>> gg.arkship')" -a \
       "$(line_of '-- <<< gg.arkship')" -lt "$(line_of 'require("hypr.bindings")')"
check "install backs up hyprland.lua" \
  test "$(find "$HOME/.config/hypr" -name 'hyprland.lua.bak.*' | wc -l)" -ge 1
check "install enables the bar widget" grep -q "omarchy plugin enable gg.arkship.global-workspaces" "$WORK/calls"
check "install reloads Hyprland" grep -q "hyprctl reload" "$WORK/calls"
check "install gives stray windows a desktop" grep -q "GlobalWorkspaces.adopt" "$WORK/calls"
check "the loader is valid Lua" luac -p "$CONFIG"

"$ROOT/setup" install --yes >/dev/null
check "installing twice does not duplicate the block" \
  test "$(grep -cF -- '-- >>> gg.arkship.global-workspaces >>>' "$CONFIG")" -eq 1

: >"$WORK/calls"
"$ROOT/setup" uninstall --yes >/dev/null
check "uninstall restores hyprland.lua exactly" cmp -s "$CONFIG" "$WORK/original.lua"
check "uninstall flattens windows before unloading" grep -q "GlobalWorkspaces.flatten" "$WORK/calls"
check "uninstall restores the stock bar widget" grep -q "omarchy plugin disable gg.arkship.global-workspaces" "$WORK/calls"

check "install refuses to edit config without a terminal or --yes" \
  bash -c '! "$0" install </dev/null >/dev/null 2>&1' "$ROOT/setup"
check "a refused install leaves hyprland.lua alone" cmp -s "$CONFIG" "$WORK/original.lua"

echo
echo "$passed passed, $failed failed"
[[ $failed -eq 0 ]]

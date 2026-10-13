#!/bin/bash

# Puts the equalizer backend on PATH so the panel and the bar widget can reach it
# by name. The plugin itself is a plain checkout, so this is the one step that
# has to happen after dropping it in -- run it once, and again if the plugin
# moves.
#
# A symlink (rather than a copy) is what keeps the installed command in step with
# the checkout: editing bin/omarchy-equalizer takes effect immediately.

set -euo pipefail

plugin_dir="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
target="${XDG_BIN_HOME:-$HOME/.local/bin}"
link="$target/omarchy-equalizer"

mkdir -p "$target"
ln -sfn "$plugin_dir/bin/omarchy-equalizer" "$link"
chmod +x "$plugin_dir/bin/omarchy-equalizer"

printf 'Linked %s -> %s\n' "$link" "$plugin_dir/bin/omarchy-equalizer"
case ":$PATH:" in
  *":$target:"*) ;;
  *) printf 'Note: %s is not on PATH. Add it to your shell profile.\n' "$target" >&2 ;;
esac

if [[ -n ${OMARCHY_PATH:-} && ! -d $OMARCHY_PATH/shell ]]; then
  printf 'Warning: OMARCHY_PATH does not point at an Omarchy install (%s).\n' "$OMARCHY_PATH" >&2
fi

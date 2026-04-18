#!/usr/bin/env bash
#
# Render the LaunchAgent plist and load it via launchctl.
#
# Environment overrides (all optional):
#   SIESTA_BIN    path to the vllm-mlx-siesta executable (default: which vllm-mlx-siesta)
#   CONFIG_PATH   path to TOML config (default: ~/.config/vllm-mlx-siesta/config.toml)
#   LOG_DIR       log directory (default: ~/Library/Logs/vllm-mlx-siesta)
#   WORKDIR       working directory (default: $HOME)
#   AGENT_PATH    PATH value injected into the LaunchAgent environment
#                 (default: /usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="$SCRIPT_DIR/com.axiomantic.vllm-mlx-siesta.plist.tmpl"

if [[ ! -f "$TEMPLATE" ]]; then
  echo "error: template not found at $TEMPLATE" >&2
  exit 1
fi

LABEL="com.axiomantic.vllm-mlx-siesta"
LAUNCH_AGENTS="$HOME/Library/LaunchAgents"
PLIST_DEST="$LAUNCH_AGENTS/$LABEL.plist"

SIESTA_BIN="${SIESTA_BIN:-$(command -v vllm-mlx-siesta || true)}"
if [[ -z "$SIESTA_BIN" ]]; then
  echo "error: vllm-mlx-siesta not found in PATH and SIESTA_BIN not set" >&2
  exit 1
fi

CONFIG_PATH="${CONFIG_PATH:-$HOME/.config/vllm-mlx-siesta/config.toml}"
LOG_DIR="${LOG_DIR:-$HOME/Library/Logs/vllm-mlx-siesta}"
WORKDIR="${WORKDIR:-$HOME}"
AGENT_PATH="${AGENT_PATH:-/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin}"

mkdir -p "$LAUNCH_AGENTS" "$LOG_DIR" "$(dirname "$CONFIG_PATH")"

escape() { printf '%s' "$1" | sed -e 's/[\/&|]/\\&/g'; }

sed \
  -e "s|__SIESTA_BIN__|$(escape "$SIESTA_BIN")|g" \
  -e "s|__CONFIG_PATH__|$(escape "$CONFIG_PATH")|g" \
  -e "s|__LOG_DIR__|$(escape "$LOG_DIR")|g" \
  -e "s|__WORKDIR__|$(escape "$WORKDIR")|g" \
  -e "s|__PATH__|$(escape "$AGENT_PATH")|g" \
  "$TEMPLATE" > "$PLIST_DEST"

launchctl unload "$PLIST_DEST" >/dev/null 2>&1 || true
launchctl load "$PLIST_DEST"

echo "Installed $PLIST_DEST"
echo "  Binary:  $SIESTA_BIN"
echo "  Config:  $CONFIG_PATH (create this before launchctl load succeeds long-term)"
echo "  Logs:    $LOG_DIR"
echo
echo "Uninstall with: launchctl unload $PLIST_DEST && rm $PLIST_DEST"

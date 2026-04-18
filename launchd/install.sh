#!/usr/bin/env bash
#
# Render the LaunchAgent plist and load it via launchctl.
#
# Assumes siesta + vllm-mlx are already installed together in a shared venv.
# The top-level install.sh handles that case automatically; use this script for
# manual installs where you've already `pip install`ed both into one venv.
#
# Environment overrides (all optional):
#   VENV_DIR      shared venv root (default: ~/.local/share/vllm-mlx-siesta/venv)
#   SIESTA_BIN    path to vllm-mlx-siesta binary (default: $VENV_DIR/bin/vllm-mlx-siesta
#                 if that exists, else `which vllm-mlx-siesta`)
#   CONFIG_PATH   path to TOML config (default: ~/.config/vllm-mlx-siesta/config.toml)
#   LOG_DIR       log directory (default: ~/Library/Logs/vllm-mlx-siesta)
#   WORKDIR       working directory (default: $HOME)
#   AGENT_PATH    PATH value injected into the LaunchAgent environment
#                 (default: <venv>/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin)

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

VENV_DIR="${VENV_DIR:-$HOME/.local/share/vllm-mlx-siesta/venv}"

if [[ -z "${SIESTA_BIN:-}" ]]; then
  if [[ -x "$VENV_DIR/bin/vllm-mlx-siesta" ]]; then
    SIESTA_BIN="$VENV_DIR/bin/vllm-mlx-siesta"
  else
    SIESTA_BIN="$(command -v vllm-mlx-siesta || true)"
  fi
fi

if [[ -z "$SIESTA_BIN" ]] || [[ ! -x "$SIESTA_BIN" ]]; then
  echo "error: vllm-mlx-siesta binary not found" >&2
  echo "  expected at $VENV_DIR/bin/vllm-mlx-siesta" >&2
  echo "  or set SIESTA_BIN=<path>" >&2
  exit 1
fi

# Sanity check: if SIESTA_BIN is in a venv, make sure vllm-mlx is in the same venv.
SIESTA_VENV_BIN_DIR="$(dirname "$SIESTA_BIN")"
if [[ -f "$SIESTA_VENV_BIN_DIR/../pyvenv.cfg" ]]; then
  if [[ ! -x "$SIESTA_VENV_BIN_DIR/vllm-mlx" ]]; then
    echo "warning: vllm-mlx not found in the same venv as siesta" >&2
    echo "         install it with: $SIESTA_VENV_BIN_DIR/pip install 'git+https://github.com/waybarrios/vllm-mlx.git'" >&2
  fi
fi

CONFIG_PATH="${CONFIG_PATH:-$HOME/.config/vllm-mlx-siesta/config.toml}"
LOG_DIR="${LOG_DIR:-$HOME/Library/Logs/vllm-mlx-siesta}"
WORKDIR="${WORKDIR:-$HOME}"
AGENT_PATH="${AGENT_PATH:-$SIESTA_VENV_BIN_DIR:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin}"

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
echo "  PATH:    $AGENT_PATH"
echo
echo "Uninstall with: launchctl unload $PLIST_DEST && rm $PLIST_DEST"

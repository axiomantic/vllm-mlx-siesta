#!/usr/bin/env bash
#
# vllm-mlx-siesta one-liner installer for macOS.
#
# Installs siesta via pipx (or uv if present), writes a default config,
# renders the LaunchAgent plist, and loads it so the proxy starts at login.
#
# Usage (curl | bash):
#   curl -fsSL https://raw.githubusercontent.com/axiomantic/vllm-mlx-siesta/main/install.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/axiomantic/vllm-mlx-siesta/main/install.sh | bash -s -- \
#       --model mlx-community/Qwen2.5-7B-Instruct-4bit \
#       --listen-port 8080 --upstream-port 8000
#
# Flags:
#   --model MODEL         HuggingFace model id (default: mlx-community/Qwen2.5-7B-Instruct-4bit)
#   --listen-port N       siesta's listen port (default: 8080)
#   --upstream-port N     vllm-mlx port (default: 8000)
#   --pause N             SIGSTOP after N seconds idle (default: 60)
#   --idle N              SIGTERM after N seconds idle (default: 600)
#   --ref REF             git ref to install from (default: main)
#   --no-launchd          skip LaunchAgent install (config + binary only)
#   --no-vllm-mlx         do NOT auto-install vllm-mlx if it's missing
#   --uninstall           reverse the install

set -euo pipefail

REPO="https://github.com/axiomantic/vllm-mlx-siesta.git"
RAW="https://raw.githubusercontent.com/axiomantic/vllm-mlx-siesta"
LABEL="com.axiomantic.vllm-mlx-siesta"

MODEL="mlx-community/Qwen2.5-7B-Instruct-4bit"
LISTEN_PORT=8080
UPSTREAM_PORT=8000
PAUSE=60
IDLE=600
REF="main"
SKIP_LAUNCHD=0
SKIP_VLLM_MLX=0
UNINSTALL=0
VLLM_MLX_REPO="https://github.com/waybarrios/vllm-mlx.git"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --model) MODEL="$2"; shift 2 ;;
    --listen-port) LISTEN_PORT="$2"; shift 2 ;;
    --upstream-port) UPSTREAM_PORT="$2"; shift 2 ;;
    --pause) PAUSE="$2"; shift 2 ;;
    --idle) IDLE="$2"; shift 2 ;;
    --ref) REF="$2"; shift 2 ;;
    --no-launchd) SKIP_LAUNCHD=1; shift ;;
    --no-vllm-mlx) SKIP_VLLM_MLX=1; shift ;;
    --uninstall) UNINSTALL=1; shift ;;
    -h|--help) sed -n '3,25p' "$0"; exit 0 ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
done

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "error: this installer is macOS only" >&2
  exit 1
fi

LAUNCH_AGENTS="$HOME/Library/LaunchAgents"
PLIST_DEST="$LAUNCH_AGENTS/$LABEL.plist"
CONFIG_DIR="$HOME/.config/vllm-mlx-siesta"
CONFIG_PATH="$CONFIG_DIR/config.toml"
LOG_DIR="$HOME/Library/Logs/vllm-mlx-siesta"

ensure_python_installer() {
  # Pick and echo: "uv", "pipx", or "" (failure). Installs pipx via brew if needed.
  if command -v uv >/dev/null 2>&1; then
    echo uv
    return
  fi
  if command -v pipx >/dev/null 2>&1; then
    echo pipx
    return
  fi
  if command -v brew >/dev/null 2>&1; then
    echo ">>  pipx not found; installing via homebrew" >&2
    brew install pipx >&2
    pipx ensurepath >&2 || true
    echo pipx
    return
  fi
  echo ""
}

install_python_tool() {
  # install_python_tool <installer> <package-name> <pip-spec>
  local installer="$1" name="$2" spec="$3"
  case "$installer" in
    uv)
      uv tool install --force --python 3.11 "$spec"
      ;;
    pipx)
      pipx install --force "$spec"
      ;;
    *)
      echo "error: unknown installer '$installer'" >&2
      return 1
      ;;
  esac
}

uninstall_python_tool() {
  local name="$1"
  if command -v uv >/dev/null 2>&1; then
    uv tool uninstall "$name" 2>/dev/null || true
  fi
  if command -v pipx >/dev/null 2>&1; then
    pipx uninstall "$name" 2>/dev/null || true
  fi
}

if [[ $UNINSTALL -eq 1 ]]; then
  if [[ -f "$PLIST_DEST" ]]; then
    launchctl unload "$PLIST_DEST" 2>/dev/null || true
    rm -f "$PLIST_DEST"
    echo "removed $PLIST_DEST"
  fi
  uninstall_python_tool vllm-mlx-siesta
  echo "(vllm-mlx itself is left installed; remove manually if desired:"
  echo "   uv tool uninstall vllm-mlx  /  pipx uninstall vllm-mlx )"
  echo "config kept at $CONFIG_PATH; remove manually if desired"
  exit 0
fi

INSTALLER="$(ensure_python_installer)"
if [[ -z "$INSTALLER" ]]; then
  echo "error: need uv, pipx, or homebrew to install Python tools" >&2
  echo "  https://github.com/astral-sh/uv  OR  https://pipx.pypa.io" >&2
  exit 1
fi

# --- 1. Install vllm-mlx (if missing) --------------------------------------------

if command -v vllm-mlx >/dev/null 2>&1; then
  echo ">> vllm-mlx already installed ($(command -v vllm-mlx))"
elif [[ $SKIP_VLLM_MLX -eq 1 ]]; then
  echo "!! vllm-mlx not found. --no-vllm-mlx set, skipping auto-install."
  echo "   LaunchAgent will fail until you install it manually:"
  echo "     $INSTALLER tool install git+$VLLM_MLX_REPO  (or pipx install ...)"
else
  echo ">> installing vllm-mlx via $INSTALLER"
  install_python_tool "$INSTALLER" vllm-mlx "git+$VLLM_MLX_REPO"
  if ! command -v vllm-mlx >/dev/null 2>&1; then
    echo "!! installed vllm-mlx but it's not on PATH yet."
    echo "   A new shell (or sourcing your shell rc) should pick it up."
  fi
fi

# --- 2. Install the siesta binary ------------------------------------------------

echo ">> installing vllm-mlx-siesta via $INSTALLER"
install_python_tool "$INSTALLER" vllm-mlx-siesta "git+$REPO@$REF"

case "$INSTALLER" in
  uv)
    SIESTA_BIN="$(uv tool dir 2>/dev/null)/vllm-mlx-siesta/bin/vllm-mlx-siesta"
    [[ -x "$SIESTA_BIN" ]] || SIESTA_BIN="$HOME/.local/bin/vllm-mlx-siesta"
    ;;
  pipx)
    SIESTA_BIN="$(pipx environment --value PIPX_BIN_DIR 2>/dev/null || echo "$HOME/.local/bin")/vllm-mlx-siesta"
    ;;
esac

if [[ ! -x "$SIESTA_BIN" ]]; then
  echo "warning: could not confirm siesta binary at $SIESTA_BIN"
  echo "         check your PATH; LaunchAgent may fail until the binary is found"
fi

# --- 3. Write config --------------------------------------------------------------

mkdir -p "$CONFIG_DIR"
if [[ -f "$CONFIG_PATH" ]]; then
  echo ">> keeping existing $CONFIG_PATH"
else
  cat > "$CONFIG_PATH" <<EOF
# Generated by vllm-mlx-siesta install.sh
listen_host = "127.0.0.1"
listen_port = $LISTEN_PORT

upstream_host = "127.0.0.1"
upstream_port = $UPSTREAM_PORT
model = "$MODEL"

pause_after_seconds = $PAUSE.0
idle_timeout_seconds = $IDLE.0
EOF
  echo ">> wrote $CONFIG_PATH"
fi

mkdir -p "$LOG_DIR"

# --- 4. LaunchAgent ---------------------------------------------------------------

if [[ $SKIP_LAUNCHD -eq 1 ]]; then
  echo ">> skipping LaunchAgent (--no-launchd)"
else
  mkdir -p "$LAUNCH_AGENTS"
  TMPL_URL="$RAW/$REF/launchd/com.axiomantic.vllm-mlx-siesta.plist.tmpl"
  TMPL="$(mktemp)"
  trap 'rm -f "$TMPL"' EXIT
  curl -fsSL -o "$TMPL" "$TMPL_URL"

  escape() { printf '%s' "$1" | sed -e 's/[\/&|]/\\&/g'; }
  AGENT_PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
  sed \
    -e "s|__SIESTA_BIN__|$(escape "$SIESTA_BIN")|g" \
    -e "s|__CONFIG_PATH__|$(escape "$CONFIG_PATH")|g" \
    -e "s|__LOG_DIR__|$(escape "$LOG_DIR")|g" \
    -e "s|__WORKDIR__|$(escape "$HOME")|g" \
    -e "s|__PATH__|$(escape "$AGENT_PATH")|g" \
    "$TMPL" > "$PLIST_DEST"

  launchctl unload "$PLIST_DEST" 2>/dev/null || true
  launchctl load "$PLIST_DEST"
  echo ">> loaded $PLIST_DEST"
fi

cat <<EOF

siesta is installed.

  binary:   $SIESTA_BIN
  config:   $CONFIG_PATH (edit to change model / timeouts)
  logs:     $LOG_DIR
  launchd:  ${PLIST_DEST}$([[ $SKIP_LAUNCHD -eq 1 ]] && echo "  (skipped)")

Test once vllm-mlx is installed:
  curl http://127.0.0.1:$LISTEN_PORT/healthz

Uninstall:
  curl -fsSL $RAW/$REF/install.sh | bash -s -- --uninstall
EOF

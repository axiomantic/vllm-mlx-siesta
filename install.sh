#!/usr/bin/env bash
#
# vllm-mlx-siesta one-liner installer for macOS.
#
# Installs vllm-mlx + siesta, writes ~/.config/vllm-mlx-siesta/config.toml,
# renders the LaunchAgent plist, and loads it so the proxy starts at login.
#
# Usage (curl | bash):
#   curl -fsSL https://raw.githubusercontent.com/axiomantic/vllm-mlx-siesta/main/install.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/axiomantic/vllm-mlx-siesta/main/install.sh | bash -s -- \
#       --model mlx-community/Qwen2.5-7B-Instruct-4bit \
#       --listen-port 8080 --upstream-port 8000
#
# Flags:
#   --model MODEL         HuggingFace model id (skip interactive selector)
#   --listen-port N       siesta's listen port (default: 8080)
#   --upstream-port N     vllm-mlx port (default: 8000)
#   --pause N             SIGSTOP after N seconds idle (default: 60)
#   --idle N              SIGTERM after N seconds idle (default: 600)
#   --force               overwrite existing ~/.config/vllm-mlx-siesta/config.toml
#   --yes, -y             accept the recommended default; don't prompt
#   --ref REF             git ref to install from (default: main)
#   --no-launchd          skip LaunchAgent install (config + binary only)
#   --no-vllm-mlx         do NOT auto-install vllm-mlx if it's missing
#   --uninstall           reverse the install (leaves config + vllm-mlx in place)

set -euo pipefail

REPO="https://github.com/axiomantic/vllm-mlx-siesta.git"
RAW="https://raw.githubusercontent.com/axiomantic/vllm-mlx-siesta"
LABEL="com.axiomantic.vllm-mlx-siesta"
VLLM_MLX_REPO="https://github.com/waybarrios/vllm-mlx.git"
MLX_COMMUNITY_URL="https://huggingface.co/mlx-community"

MODEL_CLI=""
LISTEN_PORT=8080
UPSTREAM_PORT=8000
PAUSE=60
IDLE=600
REF="main"
SKIP_LAUNCHD=0
SKIP_VLLM_MLX=0
FORCE_CONFIG=0
YES=0
UNINSTALL=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --model) MODEL_CLI="$2"; shift 2 ;;
    --listen-port) LISTEN_PORT="$2"; shift 2 ;;
    --upstream-port) UPSTREAM_PORT="$2"; shift 2 ;;
    --pause) PAUSE="$2"; shift 2 ;;
    --idle) IDLE="$2"; shift 2 ;;
    --ref) REF="$2"; shift 2 ;;
    --force) FORCE_CONFIG=1; shift ;;
    --yes|-y) YES=1; shift ;;
    --no-launchd) SKIP_LAUNCHD=1; shift ;;
    --no-vllm-mlx) SKIP_VLLM_MLX=1; shift ;;
    --uninstall) UNINSTALL=1; shift ;;
    -h|--help) sed -n '3,26p' "$0"; exit 0 ;;
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
UID_NUM="$(id -u)"

# --- helpers -------------------------------------------------------------------

ensure_python_installer() {
  # Pick and echo: "uv", "pipx", or "" (failure). Installs pipx via brew if needed.
  if command -v uv >/dev/null 2>&1; then
    echo uv; return
  fi
  if command -v pipx >/dev/null 2>&1; then
    echo pipx; return
  fi
  if command -v brew >/dev/null 2>&1; then
    echo ">> pipx not found; installing via homebrew" >&2
    brew install pipx >&2
    pipx ensurepath >&2 || true
    echo pipx; return
  fi
  echo ""
}

install_python_tool() {
  # install_python_tool <installer> <pip-spec>
  local installer="$1" spec="$2"
  case "$installer" in
    uv) uv tool install --force --python 3.11 "$spec" ;;
    pipx) pipx install --force "$spec" ;;
    *) echo "error: unknown installer '$installer'" >&2; return 1 ;;
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

detect_ram_gb() {
  local bytes
  bytes=$(sysctl -n hw.memsize 2>/dev/null || echo 0)
  echo $(( bytes / 1024 / 1024 / 1024 ))
}

default_for_ram() {
  local ram=$1
  if   (( ram <= 12 )); then echo "mlx-community/Llama-3.2-3B-Instruct-4bit"
  elif (( ram <= 20 )); then echo "mlx-community/Qwen2.5-7B-Instruct-4bit"
  elif (( ram <= 32 )); then echo "mlx-community/Qwen3-8B-4bit"
  else                       echo "mlx-community/gemma-3-27b-it-4bit"
  fi
}

list_cached_mlx_models() {
  # Print one model id per line (e.g. mlx-community/Foo-4bit), most recent first
  local cache="${HF_HOME:-$HOME/.cache/huggingface}/hub"
  [[ -d "$cache" ]] || return 0
  (cd "$cache" && ls -1t 2>/dev/null) | awk '
    /^models--mlx-community--/ {
      sub(/^models--mlx-community--/, "")
      print "mlx-community/" $0
    }
  '
}

cached_model_size() {
  # Echo "du -sh"-style size for a cached model, or empty
  local model="$1"
  local cache="${HF_HOME:-$HOME/.cache/huggingface}/hub"
  local dir
  dir="models--${model//\//--}"
  if [[ -d "$cache/$dir" ]]; then
    du -sh "$cache/$dir" 2>/dev/null | awk '{print $1}'
  fi
}

prompt_model_selection() {
  # Emits the chosen model to stdout; all prompt UI goes to stderr.
  local ram_gb="$1" default_model="$2"

  local tiers=(
    "mlx-community/Llama-3.2-3B-Instruct-4bit|~3B 4-bit, fits 8 GB+ RAM"
    "mlx-community/Qwen2.5-7B-Instruct-4bit|~7B 4-bit, fits 16 GB+ RAM"
    "mlx-community/Qwen3-8B-4bit|~8B 4-bit, fits 24 GB+ RAM"
    "mlx-community/gemma-3-27b-it-4bit|~27B 4-bit, fits 48 GB+ RAM"
  )

  local options=()
  local -i i=0
  local default_index=1

  {
    printf '\n'
    printf 'Browse all MLX-ready models: %s\n' "$MLX_COMMUNITY_URL"
    printf 'Detected %s GB RAM. Pick a model (press Enter for recommended):\n' "$ram_gb"
  } >&2

  local cached
  cached="$(list_cached_mlx_models)"
  if [[ -n "$cached" ]]; then
    printf '\nAlready installed (HuggingFace cache):\n' >&2
    while IFS= read -r m; do
      [[ -z "$m" ]] && continue
      i=$((i+1))
      options+=("$m")
      local size label
      size="$(cached_model_size "$m")"
      label="$m"
      [[ -n "$size" ]] && label+="  [${size} on disk]"
      printf '  %2d) %s\n' "$i" "$label" >&2
    done <<<"$cached"
  fi

  printf '\nRecommended defaults for your %s GB system:\n' "$ram_gb" >&2
  local entry m desc tag
  for entry in "${tiers[@]}"; do
    m="${entry%%|*}"
    desc="${entry##*|}"
    i=$((i+1))
    options+=("$m")
    tag=""
    if [[ "$m" == "$default_model" ]]; then
      tag="  ← recommended"
      default_index=$i
    fi
    printf '  %2d) %-48s %s%s\n' "$i" "$m" "$desc" "$tag" >&2
  done

  i=$((i+1))
  options+=("CUSTOM")
  printf '\n  %2d) Type a custom HuggingFace model id\n' "$i" >&2

  local choice_num
  printf '\nChoice [Enter = %d, recommended]: ' "$default_index" >&2
  if ! read -r choice_num < /dev/tty; then
    echo "$default_model"
    return
  fi
  if [[ -z "$choice_num" ]]; then
    choice_num="$default_index"
  fi
  if ! [[ "$choice_num" =~ ^[0-9]+$ ]] || (( choice_num < 1 || choice_num > ${#options[@]} )); then
    echo "(invalid choice; using recommended default)" >&2
    echo "$default_model"
    return
  fi

  local chosen="${options[$((choice_num-1))]}"
  if [[ "$chosen" == "CUSTOM" ]]; then
    printf 'Enter model id (e.g. mlx-community/Llama-3.3-70B-Instruct-4bit): ' >&2
    local custom
    if ! read -r custom < /dev/tty; then
      echo "$default_model"
      return
    fi
    if [[ -z "$custom" ]]; then
      echo "(empty; using recommended default)" >&2
      echo "$default_model"
      return
    fi
    chosen="$custom"
  fi
  echo "$chosen"
}

resolve_model() {
  # Returns the chosen model via stdout; stderr gets prompt UI and notes.
  if [[ -n "$MODEL_CLI" ]]; then
    echo "$MODEL_CLI"
    return
  fi
  local ram_gb default_model
  ram_gb="$(detect_ram_gb)"
  default_model="$(default_for_ram "$ram_gb")"
  if [[ $YES -eq 1 ]] || [[ ! -r /dev/tty ]]; then
    echo "$default_model"
    return
  fi
  prompt_model_selection "$ram_gb" "$default_model"
}

# --- uninstall path ------------------------------------------------------------

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

# --- decide what the config should contain -------------------------------------

KEEP_CONFIG=0
if [[ -f "$CONFIG_PATH" ]] && [[ $FORCE_CONFIG -eq 0 ]] && [[ -z "$MODEL_CLI" ]]; then
  KEEP_CONFIG=1
fi

MODEL=""
if [[ $KEEP_CONFIG -eq 0 ]]; then
  MODEL="$(resolve_model)"
  echo ">> model: $MODEL"
fi

INSTALLER="$(ensure_python_installer)"
if [[ -z "$INSTALLER" ]]; then
  echo "error: need uv, pipx, or homebrew to install Python tools" >&2
  echo "  https://github.com/astral-sh/uv  OR  https://pipx.pypa.io" >&2
  exit 1
fi

# --- 1. Install vllm-mlx (if missing) ------------------------------------------

if command -v vllm-mlx >/dev/null 2>&1; then
  echo ">> vllm-mlx already installed ($(command -v vllm-mlx))"
elif [[ $SKIP_VLLM_MLX -eq 1 ]]; then
  echo "!! vllm-mlx not found. --no-vllm-mlx set, skipping auto-install."
  echo "   LaunchAgent will fail until you install it manually:"
  echo "     $INSTALLER tool install git+$VLLM_MLX_REPO  (or pipx install ...)"
else
  echo ">> installing vllm-mlx via $INSTALLER"
  install_python_tool "$INSTALLER" "git+$VLLM_MLX_REPO"
  if ! command -v vllm-mlx >/dev/null 2>&1; then
    echo "!! installed vllm-mlx but it's not on PATH yet."
    echo "   A new shell (or sourcing your shell rc) should pick it up."
  fi
fi

# --- 2. Install siesta ---------------------------------------------------------

echo ">> installing vllm-mlx-siesta via $INSTALLER"
install_python_tool "$INSTALLER" "git+$REPO@$REF"

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

# --- 3. Write config -----------------------------------------------------------

mkdir -p "$CONFIG_DIR" "$LOG_DIR"

if [[ $KEEP_CONFIG -eq 1 ]]; then
  echo ">> keeping existing $CONFIG_PATH"
  echo "   (pass --force or --model to overwrite)"
else
  existed=0
  [[ -f "$CONFIG_PATH" ]] && existed=1
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
  if [[ $existed -eq 1 ]]; then
    echo ">> overwrote $CONFIG_PATH"
  else
    echo ">> wrote $CONFIG_PATH"
  fi
fi

# --- 4. LaunchAgent ------------------------------------------------------------

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

# --- 5. Summary ----------------------------------------------------------------

cat <<EOF

siesta is installed.

  binary:   $SIESTA_BIN
  config:   $CONFIG_PATH
  logs:     $LOG_DIR
  launchd:  ${PLIST_DEST}$([[ $SKIP_LAUNCHD -eq 1 ]] && echo "  (skipped)")

Test once vllm-mlx is installed:
  curl http://127.0.0.1:$LISTEN_PORT/healthz

To change model later:
  A. Edit the config and reload the LaunchAgent:
       \$EDITOR $CONFIG_PATH
       launchctl kickstart -k gui/$UID_NUM/$LABEL
  B. Re-run this installer with --force (overwrites config, re-prompts for model):
       curl -fsSL $RAW/$REF/install.sh | bash -s -- --force
     Or bypass the prompt with --model:
       curl -fsSL $RAW/$REF/install.sh | bash -s -- --force --model mlx-community/Other-Model-4bit

  Browse models: $MLX_COMMUNITY_URL

Uninstall:
  curl -fsSL $RAW/$REF/install.sh | bash -s -- --uninstall
EOF

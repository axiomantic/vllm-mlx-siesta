#!/usr/bin/env bash
#
# vllm-mlx-siesta one-liner installer for macOS.
#
# Creates a single shared venv at ~/.local/share/vllm-mlx-siesta/venv and installs
# BOTH vllm-mlx-siesta and vllm-mlx into it, so siesta can spawn vllm-mlx as a
# subprocess without PATH gymnastics. Writes ~/.config/vllm-mlx-siesta/config.toml,
# symlinks ~/.local/bin/vllm-mlx-siesta, renders the LaunchAgent plist, and loads it.
#
# Usage (curl | bash):
#   curl -fsSL https://raw.githubusercontent.com/axiomantic/vllm-mlx-siesta/main/install.sh | bash
#   curl -fsSL https://raw.githubusercontent.com/axiomantic/vllm-mlx-siesta/main/install.sh | bash -s -- \
#       --model mlx-community/Qwen2.5-7B-Instruct-4bit \
#       --listen-port 8080 --upstream-port 8000
#
# Flags:
#   --model MODEL         HuggingFace model id (skip interactive selector)
#   --listen-port N       siesta's listen port (default: 11435)
#   --upstream-port N     vllm-mlx port (default: 11436)
#   --pause N             SIGSTOP after N seconds idle (default: 60)
#   --idle N              SIGTERM after N seconds idle (default: 600)
#   --force               overwrite existing ~/.config/vllm-mlx-siesta/config.toml
#   --yes, -y             accept the recommended default; don't prompt
#   --ref REF             git ref to install from (default: main)
#   --python PATH         python interpreter to build the venv with (default: auto)
#   --no-launchd          skip LaunchAgent install (venv + config only)
#   --no-vllm-mlx         do NOT install vllm-mlx into the shared venv
#   --clean               wipe the shared venv (and unload the LaunchAgent) before
#                         installing; leaves config in place. Use when the venv is
#                         stuck or after switching Python interpreters.
#   --uninstall           reverse the install (removes venv + symlink + launchd;
#                         leaves ~/.config/vllm-mlx-siesta/ in place)

set -euo pipefail

REPO="https://github.com/axiomantic/vllm-mlx-siesta.git"
RAW="https://raw.githubusercontent.com/axiomantic/vllm-mlx-siesta"
LABEL="com.axiomantic.vllm-mlx-siesta"
VLLM_MLX_REPO="https://github.com/waybarrios/vllm-mlx.git"
MLX_COMMUNITY_URL="https://huggingface.co/mlx-community"

MODEL_CLI=""
LISTEN_PORT=11435
UPSTREAM_PORT=11436
PAUSE=60
IDLE=600
REF="main"
PYTHON_CLI=""
SKIP_LAUNCHD=0
SKIP_VLLM_MLX=0
FORCE_CONFIG=0
YES=0
CLEAN=0
UNINSTALL=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --model) MODEL_CLI="$2"; shift 2 ;;
    --listen-port) LISTEN_PORT="$2"; shift 2 ;;
    --upstream-port) UPSTREAM_PORT="$2"; shift 2 ;;
    --pause) PAUSE="$2"; shift 2 ;;
    --idle) IDLE="$2"; shift 2 ;;
    --ref) REF="$2"; shift 2 ;;
    --python) PYTHON_CLI="$2"; shift 2 ;;
    --force) FORCE_CONFIG=1; shift ;;
    --yes|-y) YES=1; shift ;;
    --no-launchd) SKIP_LAUNCHD=1; shift ;;
    --no-vllm-mlx) SKIP_VLLM_MLX=1; shift ;;
    --clean) CLEAN=1; shift ;;
    --uninstall) UNINSTALL=1; shift ;;
    -h|--help) sed -n '3,30p' "$0"; exit 0 ;;
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

VENV_DIR="$HOME/.local/share/vllm-mlx-siesta/venv"
BIN_DIR="$HOME/.local/bin"
SIESTA_SYMLINK="$BIN_DIR/vllm-mlx-siesta"
VENV_SIESTA_BIN="$VENV_DIR/bin/vllm-mlx-siesta"
VENV_VLLM_MLX_BIN="$VENV_DIR/bin/vllm-mlx"

# --- helpers -------------------------------------------------------------------

find_python() {
  # Emit a python3 interpreter path that is >= 3.11. Honors --python.
  if [[ -n "$PYTHON_CLI" ]]; then
    if ! command -v "$PYTHON_CLI" >/dev/null 2>&1; then
      echo "error: --python '$PYTHON_CLI' not found" >&2
      return 1
    fi
    echo "$PYTHON_CLI"; return
  fi
  local cand
  for cand in python3.13 python3.12 python3.11 python3; do
    if command -v "$cand" >/dev/null 2>&1; then
      local ver
      ver="$("$cand" -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null || echo "")"
      case "$ver" in
        3.11|3.12|3.13|3.14|3.15) echo "$cand"; return 0 ;;
      esac
    fi
  done
  return 1
}

ensure_venv() {
  if [[ -x "$VENV_DIR/bin/pip" ]]; then
    return
  fi
  local py
  py="$(find_python)" || {
    echo "error: need Python 3.11+ to create the venv" >&2
    echo "  brew install python@3.12   # then re-run this installer" >&2
    exit 1
  }
  echo ">> creating venv at $VENV_DIR (using $py)"
  mkdir -p "$(dirname "$VENV_DIR")"
  "$py" -m venv "$VENV_DIR"
  "$VENV_DIR/bin/pip" install --quiet --upgrade pip
}

pip_install() {
  "$VENV_DIR/bin/pip" install --upgrade "$@"
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
  if [[ -L "$SIESTA_SYMLINK" ]] || [[ -e "$SIESTA_SYMLINK" ]]; then
    rm -f "$SIESTA_SYMLINK"
    echo "removed $SIESTA_SYMLINK"
  fi
  if [[ -d "$VENV_DIR" ]]; then
    rm -rf "$VENV_DIR"
    echo "removed $VENV_DIR (includes vllm-mlx if installed)"
  fi
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

# --- 1. Venv + installs --------------------------------------------------------

if [[ $CLEAN -eq 1 ]]; then
  # Stop any running siesta bound to the old venv before wiping it.
  if [[ -f "$PLIST_DEST" ]]; then
    launchctl unload "$PLIST_DEST" 2>/dev/null || true
    echo ">> unloaded $PLIST_DEST (will reload after reinstall)"
  fi
  if [[ -L "$SIESTA_SYMLINK" ]] || [[ -e "$SIESTA_SYMLINK" ]]; then
    rm -f "$SIESTA_SYMLINK"
  fi
  if [[ -d "$VENV_DIR" ]]; then
    rm -rf "$VENV_DIR"
    echo ">> wiped $VENV_DIR"
  fi
fi

ensure_venv

if [[ $SKIP_VLLM_MLX -eq 1 ]]; then
  echo "!! --no-vllm-mlx set; not installing vllm-mlx into the venv"
  echo "   Install it later into the SAME venv (or siesta will fail to spawn it):"
  echo "     $VENV_DIR/bin/pip install 'git+$VLLM_MLX_REPO'"
else
  echo ">> installing vllm-mlx into venv"
  pip_install "git+$VLLM_MLX_REPO"
fi

echo ">> installing vllm-mlx-siesta into venv"
pip_install "git+$REPO@$REF"

mkdir -p "$BIN_DIR"
ln -sf "$VENV_SIESTA_BIN" "$SIESTA_SYMLINK"
echo ">> symlinked $SIESTA_SYMLINK -> $VENV_SIESTA_BIN"

# --- 2. Write config -----------------------------------------------------------

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

# --- 3. LaunchAgent ------------------------------------------------------------

if [[ $SKIP_LAUNCHD -eq 1 ]]; then
  echo ">> skipping LaunchAgent (--no-launchd)"
else
  mkdir -p "$LAUNCH_AGENTS"
  TMPL_URL="$RAW/$REF/launchd/com.axiomantic.vllm-mlx-siesta.plist.tmpl"
  TMPL="$(mktemp)"
  trap 'rm -f "$TMPL"' EXIT
  curl -fsSL -o "$TMPL" "$TMPL_URL"

  escape() { printf '%s' "$1" | sed -e 's/[\/&|]/\\&/g'; }
  # venv/bin FIRST so siesta's subprocess spawn of `vllm-mlx` resolves to the
  # co-installed one. Homebrew paths kept as a fallback.
  AGENT_PATH="$VENV_DIR/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
  sed \
    -e "s|__SIESTA_BIN__|$(escape "$VENV_SIESTA_BIN")|g" \
    -e "s|__CONFIG_PATH__|$(escape "$CONFIG_PATH")|g" \
    -e "s|__LOG_DIR__|$(escape "$LOG_DIR")|g" \
    -e "s|__WORKDIR__|$(escape "$HOME")|g" \
    -e "s|__PATH__|$(escape "$AGENT_PATH")|g" \
    "$TMPL" > "$PLIST_DEST"

  launchctl unload "$PLIST_DEST" 2>/dev/null || true
  launchctl load "$PLIST_DEST"
  echo ">> loaded $PLIST_DEST"
fi

# --- 4. Summary ----------------------------------------------------------------

cat <<EOF

siesta is installed.

  venv:     $VENV_DIR
  binary:   $SIESTA_SYMLINK -> $VENV_SIESTA_BIN
  config:   $CONFIG_PATH
  logs:     $LOG_DIR
  launchd:  ${PLIST_DEST}$([[ $SKIP_LAUNCHD -eq 1 ]] && echo "  (skipped)")

Test:
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

To upgrade siesta or vllm-mlx in place:
  $VENV_DIR/bin/pip install --upgrade "git+$REPO"
  $VENV_DIR/bin/pip install --upgrade "git+$VLLM_MLX_REPO"

Uninstall:
  curl -fsSL $RAW/$REF/install.sh | bash -s -- --uninstall
EOF

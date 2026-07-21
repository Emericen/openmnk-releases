#!/bin/bash
# OpenMNK agent environment bootstrap — macOS
# Installs the pinned toolchain agents rely on: Node.js, Google Workspace CLI,
# playwright-cli (+ browser), uv, Python (via uv), ctx7. Idempotent — safe to
# re-run; finished stages skip.
#
# Run:  curl -fsSL https://raw.githubusercontent.com/Emericen/openmnk-releases/main/setup/macos.sh -o /tmp/openmnk-setup.sh && bash /tmp/openmnk-setup.sh
#
# Stage selection (default = everything):
#   --skip gws            install everything except gws
#   --skip gws,python     comma list
#   --only node,uv        install ONLY these (plus auto-added prerequisites:
#                         npm CLIs pull in node; python is installed BY uv, so it pulls in uv)
# Stages: node, gws, playwright, ctx7, python, uv
#
# Output contract (for agents): every line is logged to /tmp/openmnk-setup.log.
# The FINAL line is exactly "SETUP-OK" or "SETUP-FAIL:<stage>". On failure, read the log.
#
# No sudo required anywhere. Everything is per-user: tools in ~/.openmnk/tools,
# uv + python shims in ~/.local/bin. No Homebrew dependency.

set -u

NODE_VERSION="24.18.0"
GWS_VERSION="0.22.5"
PYTHON_VERSION="3.12"
PLAYWRIGHT_CLI_VERSION="0.1.17"
CTX7_VERSION="0.5.4"
UV_VERSION="0.11.30"

ROOT="${OPENMNK_TOOLS_ROOT:-$HOME/.openmnk/tools}"
NODE_DIR="$ROOT/node"
LOCAL_BIN="$HOME/.local/bin"
LOG_FILE="/tmp/openmnk-setup.log"

log() {
  local line
  line="$(date +%H:%M:%S) $*"
  echo "$line" >> "$LOG_FILE"
  echo "$line"
}
fail() {
  log "ERROR at $1: $2"
  echo "SETUP-FAIL:$1 (details: $LOG_FILE)"
  exit 1
}
fetch() { # url out stage
  log "download $1"
  curl -fsSL --retry 3 --retry-delay 2 -o "$2" "$1" || fail "$3" "download failed: $1"
}

# ── stage selection ──────────────────────────────────────────────────────────
ALL_STAGES="node gws playwright ctx7 python uv"
ONLY=""
SKIP=""
while [ $# -gt 0 ]; do
  case "$1" in
    --only) ONLY="${2:-}"; shift 2 ;;
    --only=*) ONLY="${1#*=}"; shift ;;
    --skip) SKIP="${2:-}"; shift 2 ;;
    --skip=*) SKIP="${1#*=}"; shift ;;
    *) echo "SETUP-FAIL:args (unknown argument: $1; usage: [--only a,b] [--skip x,y])"; exit 1 ;;
  esac
done
if [ -n "$ONLY" ] && [ -n "$SKIP" ]; then
  echo "SETUP-FAIL:args (--only and --skip are mutually exclusive)"
  exit 1
fi
in_list() { # needle, comma-or-space list
  echo " $(echo "$2" | tr ',' ' ') " | grep -q " $1 "
}
SELECTED=""
if [ -n "$ONLY" ]; then
  SELECTED="$(echo "$ONLY" | tr ',' ' ')"
else
  for s in $ALL_STAGES; do
    in_list "$s" "$SKIP" || SELECTED="$SELECTED $s"
  done
fi
for s in $SELECTED; do
  in_list "$s" "$ALL_STAGES" || { echo "SETUP-FAIL:args (unknown stage: $s; valid: $(echo $ALL_STAGES | tr ' ' ','))"; exit 1; }
done
want() { in_list "$1" "$SELECTED"; }
# prerequisites: npm-installed CLIs need node; python is installed by uv
if want gws || want playwright || want ctx7; then
  want node || SELECTED="$SELECTED node"
fi
if want python && ! want uv; then
  SELECTED="$SELECTED uv"
fi

mkdir -p "$ROOT" "$LOCAL_BIN"
log "=== OpenMNK bootstrap start (stages:$(for s in $ALL_STAGES; do want "$s" && printf ' %s' "$s"; done)) ==="

# ── stage: node ──────────────────────────────────────────────────────────────
if want node; then
  case "$(uname -m)" in
    arm64) NODE_ARCH="darwin-arm64" ;;
    x86_64) NODE_ARCH="darwin-x64" ;;
    *) fail node "unsupported architecture: $(uname -m)" ;;
  esac
  if [ -x "$NODE_DIR/bin/node" ] && [ "$("$NODE_DIR/bin/node" --version)" = "v$NODE_VERSION" ]; then
    log "node: v$NODE_VERSION already installed, skip"
  else
    TARBALL="/tmp/node-v$NODE_VERSION.tar.gz"
    fetch "https://nodejs.org/dist/v$NODE_VERSION/node-v$NODE_VERSION-$NODE_ARCH.tar.gz" "$TARBALL" node
    rm -rf "$NODE_DIR" "$ROOT/_node_tmp"
    mkdir -p "$ROOT/_node_tmp"
    tar -xzf "$TARBALL" -C "$ROOT/_node_tmp" || fail node "tar extract failed"
    mv "$ROOT/_node_tmp/node-v$NODE_VERSION-$NODE_ARCH" "$NODE_DIR"
    rm -rf "$ROOT/_node_tmp"
    log "node: installed $("$NODE_DIR/bin/node" --version)"
  fi
  export PATH="$NODE_DIR/bin:$PATH"
  # persistent PATH for login shells (zsh is the macOS default)
  PROFILE_LINE="export PATH=\"$NODE_DIR/bin:\$HOME/.local/bin:\$PATH\"  # openmnk-tools"
  if [ ! -f "$HOME/.zprofile" ] || ! grep -qF "# openmnk-tools" "$HOME/.zprofile"; then
    echo "$PROFILE_LINE" >> "$HOME/.zprofile"
    log "node: added tools to PATH in ~/.zprofile"
  fi
else
  log "node: skipped (not selected)"
fi

# ── stage: npm-packages (gws / playwright / ctx7) ────────────────────────────
NPM_PKGS=""
want gws && NPM_PKGS="$NPM_PKGS @googleworkspace/cli@$GWS_VERSION"
want playwright && NPM_PKGS="$NPM_PKGS @playwright/cli@$PLAYWRIGHT_CLI_VERSION"
want ctx7 && NPM_PKGS="$NPM_PKGS ctx7@$CTX7_VERSION"
if [ -n "$NPM_PKGS" ]; then
  # shellcheck disable=SC2086
  "$NODE_DIR/bin/npm" install -g --no-fund --no-audit $NPM_PKGS >> "$LOG_FILE" 2>&1 \
    || fail npm-packages "npm install -g exit $?"
  log "npm-packages: installed$NPM_PKGS"
else
  log "npm-packages: skipped (none selected)"
fi

# ── stage: playwright-browser ────────────────────────────────────────────────
if want playwright; then
  [ -x "$NODE_DIR/bin/playwright-cli" ] || fail playwright-browser "playwright-cli not found in $NODE_DIR/bin"
  "$NODE_DIR/bin/playwright-cli" install-browser >> "$LOG_FILE" 2>&1 \
    || fail playwright-browser "install-browser exit $?"
  log "playwright-browser: installed"
else
  log "playwright-browser: skipped (not selected)"
fi

# ── stage: uv ────────────────────────────────────────────────────────────────
# Astral's pinned installer; per-user, lands in ~/.local/bin.
if want uv; then
  UV="$LOCAL_BIN/uv"
  if [ -x "$UV" ] && "$UV" --version 2>/dev/null | grep -qF "$UV_VERSION"; then
    log "uv: $UV_VERSION already installed, skip"
  else
    UV_SCRIPT="/tmp/uv-install.sh"
    fetch "https://astral.sh/uv/$UV_VERSION/install.sh" "$UV_SCRIPT" uv
    env UV_INSTALL_DIR="$LOCAL_BIN" UV_NO_MODIFY_PATH=1 sh "$UV_SCRIPT" >> "$LOG_FILE" 2>&1 \
      || fail uv "installer failed"
    [ -x "$UV" ] || fail uv "uv missing after install"
    log "uv: installed $("$UV" --version 2>/dev/null | head -1)"
  fi
  export PATH="$LOCAL_BIN:$PATH"
else
  log "uv: skipped (not selected)"
fi

# ── stage: python (managed by uv) ────────────────────────────────────────────
# uv-managed CPython: per-user, no sudo, no python.org pkg. We symlink python3/
# python into ~/.local/bin so agents get the pinned interpreter on PATH.
if want python; then
  UV="$LOCAL_BIN/uv"
  "$UV" python install "$PYTHON_VERSION" >> "$LOG_FILE" 2>&1 \
    || fail python "uv python install $PYTHON_VERSION failed"
  PY_PATH="$("$UV" python find "$PYTHON_VERSION" 2>/dev/null)"
  [ -n "$PY_PATH" ] && [ -x "$PY_PATH" ] || fail python "uv python find returned nothing"
  ln -sf "$PY_PATH" "$LOCAL_BIN/python3"
  ln -sf "$PY_PATH" "$LOCAL_BIN/python"
  log "python: installed $("$LOCAL_BIN/python3" --version 2>&1) at $PY_PATH"
else
  log "python: skipped (not selected)"
fi

# ── verify ───────────────────────────────────────────────────────────────────
VERSIONS=""
PATHS=""
if want node; then
  VERSIONS="$VERSIONS node=$("$NODE_DIR/bin/node" --version 2>&1) npm=$("$NODE_DIR/bin/npm" --version 2>&1)"
  PATHS="$PATHS node=$NODE_DIR/bin/node npm=$NODE_DIR/bin/npm"
fi
if want gws; then
  VERSIONS="$VERSIONS gws=$("$NODE_DIR/bin/gws" --version 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
  PATHS="$PATHS gws=$NODE_DIR/bin/gws"
fi
if want playwright; then
  VERSIONS="$VERSIONS playwright-cli=$("$NODE_DIR/bin/playwright-cli" --version 2>&1 | tail -1)"
  PATHS="$PATHS playwright-cli=$NODE_DIR/bin/playwright-cli"
fi
if want python; then
  VERSIONS="$VERSIONS python=$("$LOCAL_BIN/python3" --version 2>&1)"
  PATHS="$PATHS python=$LOCAL_BIN/python3"
fi
if want uv; then
  VERSIONS="$VERSIONS uv=$("$LOCAL_BIN/uv" --version 2>&1 | head -1)"
  PATHS="$PATHS uv=$LOCAL_BIN/uv"
fi
log "=== versions:$VERSIONS ==="
# Shells spawned by an app that was already running BEFORE this script ran inherit a stale
# PATH. Print absolute paths so agents can keep working without an app restart.
log "=== paths:$PATHS ==="
log "note: if a tool is 'not found' in this session, use the absolute paths above (or restart the app); new shells opened after app restart will have them on PATH"

echo "SETUP-OK"

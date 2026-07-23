#!/bin/bash
# OpenMNK Tax Analyst environment — macOS
# Installs exactly what the Tax Analyst agent needs, nothing else:
#   - uv (pinned) and a Python 3.12 venv (per-user, no sudo, no Homebrew)
#   - pinned document libraries: pypdfium2, pypdf, rapidocr, openpyxl, python-docx
#   - the `digitize` command (intake folder -> machine-readable _ocr twin)
# Idempotent — safe to re-run; finished steps skip.
#
# Run:  curl -fsSL https://raw.githubusercontent.com/Emericen/openmnk-releases/main/tax-analyst/macos-setup.sh -o /tmp/tax-setup.sh && bash /tmp/tax-setup.sh
#
# Output contract (for agents): every line is logged to /tmp/tax-analyst-setup.log.
# The FINAL line is exactly "SETUP-OK" or "SETUP-FAIL:<step>". On failure, read the log.

set -u

PYTHON_VERSION="3.12.10"
UV_VERSION="0.11.30"
DOC_LIBS="pypdfium2==5.12.1 pypdf==6.14.2 rapidocr-onnxruntime==1.4.4 openpyxl==3.1.5 python-docx==1.2.0"
DIGITIZE_URL="https://raw.githubusercontent.com/Emericen/openmnk-releases/main/tax-analyst/digitize.py"

ROOT="${OPENMNK_TOOLS_ROOT:-$HOME/.openmnk/tax-analyst}"
LOCAL_BIN="$HOME/.local/bin"
VENV="$ROOT/pyenv"
LOG_FILE="/tmp/tax-analyst-setup.log"

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
fetch() { # url out step
  log "download $1"
  curl -fsSL --retry 3 --retry-delay 2 -o "$2" "$1" || fail "$3" "download failed: $1"
}

mkdir -p "$ROOT" "$LOCAL_BIN"
log "=== Tax Analyst setup start (python=$PYTHON_VERSION uv=$UV_VERSION) ==="

# ── step: uv ─────────────────────────────────────────────────────────────────
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

# ── step: python venv ────────────────────────────────────────────────────────
# uv-managed interpreters are externally managed (PEP 668) — pip installs into them
# fail. A seeded venv makes `pip install` work for agents and for this script.
"$UV" python install "$PYTHON_VERSION" >> "$LOG_FILE" 2>&1 \
  || fail python "uv python install $PYTHON_VERSION failed"
if [ ! -x "$VENV/bin/python" ]; then
  "$UV" venv --seed --python "$PYTHON_VERSION" "$VENV" >> "$LOG_FILE" 2>&1 \
    || fail python "uv venv creation failed"
fi
# exec wrappers, NOT symlinks: python resolves symlinks down to the base interpreter,
# which silently bypasses the venv (its site-packages disappear).
printf '#!/bin/sh\nexec "%s" "$@"\n' "$VENV/bin/python" > "$LOCAL_BIN/python3"
printf '#!/bin/sh\nexec "%s" "$@"\n' "$VENV/bin/python" > "$LOCAL_BIN/python"
chmod +x "$LOCAL_BIN/python3" "$LOCAL_BIN/python"
log "python: $("$LOCAL_BIN/python3" --version 2>&1) (venv at $VENV)"

# ── step: document libraries ─────────────────────────────────────────────────
# shellcheck disable=SC2086
"$VENV/bin/python" -m pip install --quiet --disable-pip-version-check $DOC_LIBS >> "$LOG_FILE" 2>&1 \
  || fail doc-libs "pip install failed"
"$LOCAL_BIN/python3" -c "import pypdfium2, pypdf, rapidocr_onnxruntime, openpyxl, docx" \
  >> "$LOG_FILE" 2>&1 || fail doc-libs "libraries not importable via python3 shim"
log "doc-libs: installed and importable"

# ── step: digitize command ───────────────────────────────────────────────────
fetch "$DIGITIZE_URL" "$ROOT/digitize.py" digitize
printf '#!/bin/sh\nexec "%s" "%s" "$@"\n' "$VENV/bin/python" "$ROOT/digitize.py" > "$LOCAL_BIN/digitize"
chmod +x "$LOCAL_BIN/digitize"
# persistent PATH for login shells (zsh is the macOS default)
if [ ! -f "$HOME/.zprofile" ] || ! grep -qF "# openmnk-tools" "$HOME/.zprofile"; then
  echo "export PATH=\"\$HOME/.local/bin:\$PATH\"  # openmnk-tools" >> "$HOME/.zprofile"
  log "digitize: added $LOCAL_BIN to PATH in ~/.zprofile"
fi
log "digitize: installed at $LOCAL_BIN/digitize"

# ── verify ───────────────────────────────────────────────────────────────────
log "=== versions: python=$("$LOCAL_BIN/python3" --version 2>&1) uv=$("$UV" --version 2>/dev/null | head -1) ==="
log "=== paths: python=$LOCAL_BIN/python3 digitize=$LOCAL_BIN/digitize ==="
log "note: if a tool is 'not found' in this session, use the absolute paths above"

echo "SETUP-OK"

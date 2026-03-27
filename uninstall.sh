#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/whisper-dictation"
BIN_DIR="$HOME/.local/bin"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/whisper-dictation"
SCHEMA="org.gnome.settings-daemon.plugins.media-keys"
BINDING_PATH="/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom-whisper-dictation/"

PURGE=false
if [ "${1:-}" = "--purge" ]; then
    PURGE=true
fi

# ── Stop daemon ────────────────────────────────────────────────────────────────

echo "==> Stopping daemon..."
pkill -f "whisper-daemon.py" 2>/dev/null || true
rm -f "/tmp/whisper-dictation-$(id -u).sock" \
      "/tmp/whisper-dictation-$(id -u).state" \
      "/tmp/whisper-dictation-$(id -u).lock"

# ── Remove GNOME keybinding ────────────────────────────────────────────────────

echo "==> Removing GNOME keybinding..."
EXISTING=$(gsettings get "$SCHEMA" custom-keybindings 2>/dev/null || echo "@as []")
if echo "$EXISTING" | grep -q "custom-whisper-dictation"; then
    NEW=$(echo "$EXISTING" | sed "s|, '$BINDING_PATH'||g; s|'$BINDING_PATH', ||g; s|'$BINDING_PATH'||g")
    # Normalise empty list variants
    NEW=$(echo "$NEW" | sed "s|\[\s*\]|[]|g")
    gsettings set "$SCHEMA" custom-keybindings "$NEW"
    # Reset the binding subkeys
    gsettings reset "${SCHEMA}.custom-keybinding:${BINDING_PATH}" name    2>/dev/null || true
    gsettings reset "${SCHEMA}.custom-keybinding:${BINDING_PATH}" command 2>/dev/null || true
    gsettings reset "${SCHEMA}.custom-keybinding:${BINDING_PATH}" binding 2>/dev/null || true
    echo "    Keybinding removed."
else
    echo "    No keybinding found, skipping."
fi

# ── Remove toggle script ───────────────────────────────────────────────────────

echo "==> Removing toggle script..."
rm -f "$BIN_DIR/whisper-dictation-toggle"

# ── Remove installation directory (venv + daemon) ─────────────────────────────

echo "==> Removing installation directory..."
rm -rf "$INSTALL_DIR"

# ── Config ─────────────────────────────────────────────────────────────────────

if $PURGE; then
    echo "==> Removing config directory (--purge)..."
    rm -rf "$CONFIG_DIR"
fi

# ── Done ───────────────────────────────────────────────────────────────────────

echo ""
echo "==> Uninstall complete."
echo ""
if ! $PURGE; then
    echo "The following were preserved:"
    echo "  Config : $CONFIG_DIR"
    echo "           (remove manually, or re-run with --purge)"
fi
echo "  HF model cache : ${XDG_CACHE_HOME:-$HOME/.cache}/huggingface"
echo "           (shared with other tools; remove manually if no longer needed)"

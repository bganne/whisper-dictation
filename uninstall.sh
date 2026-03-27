#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/whisper-dictation"
BIN_DIR="$HOME/.local/bin"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/whisper-dictation"
RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp}"
SCHEMA="org.gnome.settings-daemon.plugins.media-keys"
BINDING_PATH="/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom-whisper-dictation/"

PURGE=false
if [ "${1:-}" = "--purge" ]; then
    PURGE=true
fi

# ── Stop daemon ────────────────────────────────────────────────────────────────

echo "==> Stopping daemon..."
if systemctl --user is-enabled whisper-dictation.service &>/dev/null; then
    systemctl --user stop whisper-dictation.service 2>/dev/null || true
    systemctl --user disable whisper-dictation.service 2>/dev/null || true
fi
pkill -f "whisper-daemon" 2>/dev/null || true
rm -f "$RUNTIME_DIR/whisper-dictation-$(id -u).sock" \
      "$RUNTIME_DIR/whisper-dictation-$(id -u).state" \
      "$RUNTIME_DIR/whisper-dictation-$(id -u).lock" \
      "$RUNTIME_DIR/whisper-dictation-$(id -u).confhash" \
      "$RUNTIME_DIR/whisper-dictation-$(id -u).fifo"

# ── Remove systemd service ────────────────────────────────────────────────────

echo "==> Removing systemd user service..."
rm -f "$HOME/.config/systemd/user/whisper-dictation.service"
systemctl --user daemon-reload 2>/dev/null || true

# ── Remove GNOME keybinding ────────────────────────────────────────────────────

echo "==> Removing GNOME keybinding..."
EXISTING=$(gsettings get "$SCHEMA" custom-keybindings 2>/dev/null || echo "@as []")
if echo "$EXISTING" | grep -q "custom-whisper-dictation"; then
    NEW=$(echo "$EXISTING" | sed "s|, '$BINDING_PATH'||g; s|'$BINDING_PATH', ||g; s|'$BINDING_PATH'||g")
    NEW=$(echo "$NEW" | sed "s|\[\s*\]|[]|g")
    gsettings set "$SCHEMA" custom-keybindings "$NEW"
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

# ── Remove installation directory ──────────────────────────────────────────────

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

# whisper-dictation

Press a key, speak, pause — your words appear at the cursor. Powered by
[whisper.cpp](https://github.com/ggerganov/whisper.cpp) with automatic Intel
iGPU acceleration via SYCL or Vulkan.

A persistent daemon keeps the model loaded in memory so every toggle after the
first is instant, with no per-use startup cost.

---

## Requirements

- **OS**: Ubuntu 22.04+ or Debian 12+
- **Desktop**: GNOME (for keybinding registration)
- **Display server**: X11 (Wayland is **not** supported — `xdotool` and `osd_cat` require X11)
- **Audio**: PulseAudio or PipeWire-Pulse
- **Intel iGPU**: optional — enables faster transcription (see [docs/gpu.md](docs/gpu.md))

Build dependencies (installed automatically by `install.sh`):
`build-essential cmake git libsdl2-dev xdotool socat xosd-bin curl`

---

## Quick Start

```bash
git clone https://github.com/yourname/whisper-dictation
cd whisper-dictation
./install.sh
```

Press **F12** to start dictation. Speak. Pause — the transcription is typed at
the cursor automatically. Press **F12** again to stop early.

The first press after a reboot loads the model (~2-3 s). All subsequent presses
are instant.

---

## Configuration

On first install, `~/.config/whisper-dictation/whisper-dictation.conf` is created
from `whisper-dictation.conf.example`. Re-running `install.sh` never overwrites it.

| Key | Default | Description |
|-----|---------|-------------|
| `WHISPER_MODEL` | `medium.en` | Model to use (see [Model Selection](#model-selection)) |
| `WHISPER_LANGUAGE` | `en` | Language code (empty = auto-detect) |
| `GNOME_KEYBINDING` | `F12` | Key registered in GNOME |
| `THREADS` | `4` | Threads for whisper.cpp inference |
| `STREAM_LENGTH` | `10000` | Audio buffer length in ms |
| `VAD_THRESHOLD` | `0.6` | VAD sensitivity (0.0–1.0, lower = more sensitive) |
| `FREQ_THRESHOLD` | `100.0` | High-pass frequency filter in Hz |
| `EXTRA_STREAM_ARGS` | (empty) | Extra flags passed to whisper-stream |
| `OSD_FONT` | Adobe Helvetica 36 | X11 font string for on-screen display |
| `OSD_COLOR` | `red` | OSD text colour (X11 name or `#RRGGBB`) |
| `OSD_OUTLINE` | `2` | OSD text outline thickness in pixels |
| `OSD_POS` | `bottom` | OSD vertical position: `top` / `middle` / `bottom` |
| `OSD_ALIGN` | `right` | OSD horizontal alignment: `left` / `center` / `right` |
| `OSD_OFFSET` | `20` | OSD offset from screen edge in pixels |

Environment variables override config file values. Example:

```bash
WHISPER_MODEL=small.en whisper-dictation-toggle
```

After changing the config, the new values take effect the next time you press the
toggle key — the daemon detects config changes and restarts automatically.

---

## How It Works

```
F12
 └─► whisper-dictation-toggle
       ├─ daemon not running? → spawn whisper-daemon (loads model, ~2-3 s)
       └─ daemon running?     → send "start" or "stop" via Unix socket

whisper-daemon
 └─► whisper-stream (whisper.cpp)
       └─► SDL2 audio → built-in VAD → transcription
             └─► parse output → xdotool type → text appears at cursor
```

The toggle script tracks on/off state in `$XDG_RUNTIME_DIR/whisper-dictation-<uid>.state`.
The daemon runs until killed or the machine reboots.

---

## Model Selection

| Model | GGML Size | English WER | Relative speed |
|-------|-----------|-------------|----------------|
| `tiny.en` | ~75 MB | high | fastest |
| `base.en` | ~145 MB | good | fast |
| `small.en` | ~465 MB | better | moderate |
| `medium.en` | ~1.5 GB | best (English-only) | slow |
| `large-v3` | ~3 GB | best (multilingual) | slowest |

For multilingual dictation use `large-v3` and set `WHISPER_LANGUAGE=""` (auto-detect)
or set it to your language code.

Change the model in your config file and re-run `./install.sh` to download the
new GGML model file.

---

## GPU Acceleration

`install.sh` automatically detects Intel iGPUs and installs GPU acceleration:

1. **SYCL** (preferred) — Intel oneAPI DPC++ compiler, best performance on Intel Arc
2. **Vulkan** (fallback) — cross-vendor, good performance
3. **CPU** — no GPU deps needed

See [docs/gpu.md](docs/gpu.md) for details, manual setup, and how to force a
specific backend.

---

## Upgrading

```bash
git pull
./install.sh
```

`install.sh` is idempotent — it only does work that's actually needed. To force
a rebuild of whisper.cpp (e.g., after changing GPU backend):

```bash
rm -rf ~/.local/share/whisper-dictation/build
./install.sh
```

---

## Uninstalling

```bash
./uninstall.sh
```

This removes the daemon, toggle script, whisper.cpp build, and GNOME keybinding.
Your config (`~/.config/whisper-dictation/`) is preserved. To remove it too:

```bash
./uninstall.sh --purge
```

GGML models are stored inside the install directory and are removed with it.

---

## Troubleshooting

**Daemon not starting / no OSD after first F12**
Run the toggle script in a terminal to see errors:
```bash
whisper-dictation-toggle
```

**No audio captured**
Verify SDL2 can see your audio device:
```bash
~/.local/share/whisper-dictation/build/bin/whisper-stream --list-devices
```
Check that PulseAudio or PipeWire-Pulse is running: `pactl info`.

**OSD not showing**
Confirm `osd_cat` is installed and your `DISPLAY` is set:
```bash
echo "test" | osd_cat --pos=bottom --align=right --delay=3
```

**Transcription in the wrong language**
Set `WHISPER_LANGUAGE=""` (auto-detect) or set it to your language code.
Use a multilingual model (`large-v3`) instead of an `.en` model.

**Transcription is slow**
- Switch to a smaller model (`small.en` or `base.en`)
- Check whether GPU acceleration is active: look for GPU flags in `install.sh` output
- See [docs/gpu.md](docs/gpu.md) for GPU setup

**Not working under Wayland**
This project uses `xdotool` and `osd_cat`, which are X11-only. On GNOME, you can
switch to Xorg at the login screen. Wayland support would require replacing
`xdotool type` with `wtype` or `ydotool`, and `osd_cat` with a Wayland-native
notification method.

**Managing the daemon with systemd**
The install script registers a systemd user service. You can manage it with:
```bash
systemctl --user start whisper-dictation    # start the daemon
systemctl --user stop whisper-dictation     # stop the daemon
systemctl --user restart whisper-dictation  # restart after config changes
journalctl --user -u whisper-dictation -f   # view logs
```

---

## Security Notes

- The Unix socket is created in `$XDG_RUNTIME_DIR` with mode 0600, accessible
  only to the owning user.
- `xdotool type` is used with `--clearmodifiers` and `--` to prevent flag
  injection. Whisper hallucinations could theoretically produce unexpected text
  (e.g., shell metacharacters typed into a terminal), but this is inherent to
  any speech-to-type tool. Exercise caution when dictating into a terminal
  emulator or any context where typed text is interpreted as commands.

---

## License

MIT

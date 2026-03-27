# whisper-dictation

Press a key, speak, pause — your words appear at the cursor. Powered by
[faster-whisper](https://github.com/guillaumekynast/faster-whisper) with optional
Intel iGPU acceleration via OpenVINO.

A persistent daemon keeps the model loaded in memory so every toggle after the
first is instant, with no per-use startup cost.

---

## Requirements

- **OS**: Ubuntu 22.04+ or Debian 12+
- **Desktop**: GNOME (for keybinding registration)
- **Display server**: X11 (Wayland is **not** supported — `xdotool` and `osd_cat` require X11)
- **Audio**: PulseAudio or PipeWire-Pulse
- **Python**: 3.10+
- **Intel iGPU**: optional — enables faster transcription (see [docs/openvino.md](docs/openvino.md))

---

## Quick Start

```bash
git clone https://github.com/yourname/whisper-dictation
cd whisper-dictation
./install.sh
```

Press **F12** to start dictation. Speak. Pause — the transcription is typed at
the cursor automatically. Press **F12** again to stop early.

The first press after a reboot loads the model (~10 s). All subsequent presses
are instant.

---

## Configuration

On first install, `~/.config/whisper-dictation/whisper-dictation.conf` is created
from `whisper-dictation.conf.example`. Re-running `install.sh` never overwrites it.

| Key | Default | Description |
|-----|---------|-------------|
| `WHISPER_MODEL` | `medium.en` | Model to use (see [Model Selection](#model-selection)) |
| `GNOME_KEYBINDING` | `F12` | Key registered in GNOME |
| `SAMPLE_RATE` | `16000` | Audio sample rate in Hz |
| `MAX_SPEECH_SECONDS` | `120` | Maximum speech seconds before auto-flush to transcription |
| `SILENCE_RMS` | `300` | RMS threshold below which audio is silence (0–32767) |
| `SILENCE_SECONDS` | `1.5` | Seconds of silence before auto-transcription fires |
| `MIN_SPEECH_SECONDS` | `0.3` | Minimum speech seconds to bother transcribing |
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
       ├─ daemon not running? → spawn whisper-daemon.py (loads model once, ~10 s)
       └─ daemon running?     → send "start" or "stop" via Unix socket

whisper-daemon.py
 └─► parec (PulseAudio) → 16-bit PCM chunks
       └─► RMS VAD → silence detected after speech?
             └─► faster-whisper or OpenVINO → text
                   └─► xdotool type → text appears at cursor
```

The toggle script tracks on/off state in `/tmp/whisper-dictation-<uid>.state`.
The daemon runs until killed or the machine reboots.

---

## Model Selection

| Model | Size | English WER | Relative speed (CPU) |
|-------|------|-------------|----------------------|
| `tiny.en` | ~75 MB | high | fastest |
| `base.en` | ~145 MB | good | fast |
| `small.en` | ~465 MB | better | moderate |
| `medium.en` | ~1.5 GB | best (English-only) | slow |
| `large-v3` | ~3 GB | best (multilingual) | slowest |

For multilingual dictation use `large-v3` (drop the `.en` suffix) and remove
`language="en"` from `whisper-daemon.py:model.transcribe(...)`.

Change the model in your config file, delete the old model cache if desired, and
re-run `./install.sh` to download and optionally convert the new model.

---

## OpenVINO / Intel iGPU

If an Intel GPU is detected at install time, the model is converted to OpenVINO
IR format for faster transcription on the iGPU. See [docs/openvino.md](docs/openvino.md)
for details, GPU requirements, and how to force re-conversion.

---

## Upgrading

```bash
git pull
./install.sh
```

`install.sh` always copies the latest source files from the repo. Model download
and OpenVINO conversion are skipped if already done.

---

## Uninstalling

```bash
./uninstall.sh
```

This removes the daemon, toggle script, Python venv, and GNOME keybinding.
Your config (`~/.config/whisper-dictation/`) and the HuggingFace model cache
are preserved. To remove the config too:

```bash
./uninstall.sh --purge
```

The HuggingFace cache (`~/.cache/huggingface/`) is never touched as it may be
shared with other tools. Remove it manually if no longer needed.

---

## Troubleshooting

**Daemon not starting / no OSD after first F12**
Run the toggle script in a terminal to see errors:
```bash
whisper-dictation-toggle
```

**No audio captured**
Verify `parec` works:
```bash
parec --format=s16le --rate=16000 --channels=1 | head -c 1000 | xxd
```
Check that PulseAudio or PipeWire-Pulse is running: `pactl info`.

**OSD not showing**
Confirm `osd_cat` is installed and your `DISPLAY` is set:
```bash
echo "test" | osd_cat --pos=bottom --align=right --delay=3
```

**Transcription in the wrong language**
Use `medium` (multilingual) instead of `medium.en`, and either remove the
`language="en"` parameter in `whisper-daemon.py` or set it to your language code.

**Transcription is slow**
- Switch to a smaller model (`small.en` or `base.en`)
- Check whether OpenVINO conversion ran: `ls ~/.local/share/whisper-dictation/ov-model/`
- See [docs/openvino.md](docs/openvino.md) for iGPU setup

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

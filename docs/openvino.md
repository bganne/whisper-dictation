# OpenVINO / Intel iGPU Acceleration

Whisper dictation can run Whisper on an Intel integrated GPU (iGPU) using Intel's
[OpenVINO](https://github.com/openvinotoolkit/openvino) runtime. This typically
gives 2–4× faster transcription compared to the CPU path on the same hardware.

---

## How It Works

During `install.sh`, the script checks for an Intel GPU via `openvino.Core().available_devices`.
If one is found, it converts the Whisper model to OpenVINO's IR (Intermediate Representation)
format and saves it to `~/.local/share/whisper-dictation/ov-model/`.

At runtime, `whisper-daemon.py` checks whether `ov-model/` exists next to itself:
- **Present** → loads the OpenVINO model on the GPU, shows `loading on iGPU...`
- **Absent** → falls back to `faster-whisper` on CPU, shows `loading on CPU...`

---

## Requirements

- Intel CPU with integrated graphics (6th gen "Skylake" or newer recommended)
- Linux kernel GPU driver loaded (i915 for Intel)
- OpenCL runtime: install `intel-opencl-icd` if the GPU is not detected:
  ```bash
  sudo apt-get install intel-opencl-icd
  ```
- Verify GPU is visible to OpenVINO:
  ```bash
  ~/.local/share/whisper-dictation/venv/bin/python3 -c \
    "import openvino as ov; print(ov.Core().available_devices)"
  # Should include 'GPU'
  ```

---

## Verifying the Conversion Ran

```bash
ls ~/.local/share/whisper-dictation/ov-model/
# Should contain: config.json, openvino_*.xml, openvino_*.bin, tokenizer files, etc.
```

If the directory is empty or missing, the conversion was skipped (no GPU detected at install time).

---

## Forcing Re-Conversion

Delete the `ov-model/` directory and re-run `install.sh`:

```bash
rm -rf ~/.local/share/whisper-dictation/ov-model
./install.sh
```

You might want to do this after:
- Changing `WHISPER_MODEL` in your config (the converted model is model-specific)
- Installing the Intel OpenCL driver after the initial install
- Upgrading OpenVINO or `optimum-intel`

---

## Skipping OpenVINO (Force CPU)

To use the CPU path even when an Intel GPU is present, prevent conversion by
creating the directory as an empty placeholder before installing:

```bash
mkdir -p ~/.local/share/whisper-dictation/ov-model
./install.sh
```

`install.sh` checks for the directory's existence, not its contents, so an empty
directory causes conversion to be skipped. `whisper-daemon.py` checks `os.path.isdir()`,
so an empty `ov-model/` directory will cause the OpenVINO load to fail at runtime.
To reliably force CPU: simply delete `ov-model/` and do not re-run `install.sh`
with a GPU present.

A cleaner approach: set `WHISPER_MODEL` to a model that has no pre-converted
counterpart, or remove `ov-model/` and set an environment variable to skip:

```bash
rm -rf ~/.local/share/whisper-dictation/ov-model
```

The daemon will use CPU automatically.

---

## Known Limitations

- Conversion runs on CPU even when a GPU is present (`device="CPU"` in the
  `from_pretrained` call). This is intentional — OpenVINO model export is a
  CPU-side operation; only inference uses the GPU.
- The first inference after loading may be slower than subsequent ones due to
  OpenVINO's JIT compilation ("warm-up").
- `large-v3` conversion requires ~8 GB of RAM and may take 10–15 minutes.
- Only Intel GPUs are supported via this path. NVIDIA/AMD users should use the
  CPU path or configure `faster-whisper` with CUDA separately.

#!/usr/bin/env python3
"""
Whisper dictation daemon.
Loads model once, listens on a Unix socket for start/stop commands.
"""
import os
import sys
import shlex
import signal
import socket
import struct
import math
import tempfile
import subprocess
import wave
import threading

# ── Config loading ─────────────────────────────────────────────────────────────

_CONFIG_PATH = os.path.join(
    os.environ.get("XDG_CONFIG_HOME", os.path.expanduser("~/.config")),
    "whisper-dictation", "whisper-dictation.conf"
)

def _load_conf():
    """Parse a KEY=value shell-sourceable config file. No external deps."""
    conf = {}
    try:
        with open(_CONFIG_PATH) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                if "=" in line:
                    k, _, v = line.partition("=")
                    v = v.strip()
                    try:
                        conf[k.strip()] = shlex.split(v)[0] if v else ""
                    except ValueError:
                        conf[k.strip()] = v.strip("\"'")
    except FileNotFoundError:
        pass
    return conf

_conf = _load_conf()

def _get(key, default):
    """Return value for key: env var > config file > default. Casts to type of default."""
    val = os.environ.get(key) or _conf.get(key)
    if val is None:
        return default
    try:
        return type(default)(val)
    except (ValueError, TypeError):
        return default

# ── Constants (all configurable) ───────────────────────────────────────────────

_runtime_dir = os.environ.get("XDG_RUNTIME_DIR", "/tmp")
SOCKET_PATH        = os.path.join(_runtime_dir, f"whisper-dictation-{os.getuid()}.sock")
MODEL_NAME         = _get("WHISPER_MODEL", "medium.en")
SAMPLE_RATE        = _get("SAMPLE_RATE", 16000)
SILENCE_RMS        = _get("SILENCE_RMS", 300)
SILENCE_SECONDS    = _get("SILENCE_SECONDS", 1.5)
MIN_SPEECH_SECONDS = _get("MIN_SPEECH_SECONDS", 0.3)
MAX_SPEECH_SECONDS = _get("MAX_SPEECH_SECONDS", 120.0)

OSD_ARGS = [
    f"--pos={_get('OSD_POS', 'bottom')}",
    f"--align={_get('OSD_ALIGN', 'right')}",
    f"--offset={_get('OSD_OFFSET', 20)}",
    f"--font={_get('OSD_FONT', '-adobe-helvetica-bold-r-normal--36-0-0-0-p-0-iso8859-1')}",
    f"--colour={_get('OSD_COLOR', 'red')}",
    f"--outline={_get('OSD_OUTLINE', 2)}",
]

OV_MODEL_DIR = os.path.join(os.path.dirname(__file__), "ov-model")

# ── OSD ────────────────────────────────────────────────────────────────────────

_osd_proc = None
_osd_lock = threading.Lock()

def osd(msg, persistent=False):
    global _osd_proc
    with _osd_lock:
        if _osd_proc is not None:
            _osd_proc.terminate()
            _osd_proc.wait()
            _osd_proc = None
        if msg is None:
            return
        delay = ["--delay=-1"] if persistent else ["--delay=1"]
        p = subprocess.Popen(
            ["osd_cat"] + OSD_ARGS + delay,
            stdin=subprocess.PIPE
        )
        p.stdin.write(msg.encode())
        p.stdin.close()
        if persistent:
            _osd_proc = p
        # never block — fire and forget for non-persistent too

# ── Recording state ────────────────────────────────────────────────────────────

_use_openvino = False
_ov_model = None
_ov_processor = None
model = None

parec_proc = None
recording_active = False  # True while recording is on
session_id = 0            # incremented on each stop to cancel in-flight transcriptions
recording_lock = threading.Lock()

# ── Audio helpers ──────────────────────────────────────────────────────────────

def rms(data):
    count = len(data) // 2
    if not count:
        return 0
    samples = struct.unpack(f"<{count}h", data)
    return math.sqrt(sum(s * s for s in samples) / count)

# ── Transcription ──────────────────────────────────────────────────────────────

def transcribe(data, my_session):
    # Bail immediately if session was cancelled (stop command)
    with recording_lock:
        if session_id != my_session:
            return
    osd("transcribing...", persistent=True)
    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as f:
        tmpfile = f.name
    try:
        with wave.open(tmpfile, "wb") as wf:
            wf.setnchannels(1)
            wf.setsampwidth(2)
            wf.setframerate(SAMPLE_RATE)
            wf.writeframes(data)
        if _use_openvino:
            import numpy as np
            with wave.open(tmpfile, "rb") as wf:
                raw = wf.readframes(wf.getnframes())
            audio = np.frombuffer(raw, dtype=np.int16).astype(np.float32) / 32768.0
            inputs = _ov_processor(audio, return_tensors="pt", sampling_rate=SAMPLE_RATE)
            ids = _ov_model.generate(**inputs)
            text = _ov_processor.batch_decode(ids, skip_special_tokens=True)[0].strip()
        else:
            segments, _ = model.transcribe(tmpfile, language="en", beam_size=5)
            text = " ".join(seg.text.strip() for seg in segments).strip()
    finally:
        if os.path.exists(tmpfile):
            os.unlink(tmpfile)
    # Check again — may have been cancelled while transcribing
    with recording_lock:
        if session_id != my_session:
            osd(None)
            return
    if text:
        osd(None)  # clear just before typing
        subprocess.run(["xdotool", "type", "--clearmodifiers", "--delay", "0", "--", text])
    else:
        osd(None)
    osd("* REC *", persistent=True)

# ── Recording control ──────────────────────────────────────────────────────────

def start_recording():
    global parec_proc, recording_active, session_id
    with recording_lock:
        if parec_proc is not None:
            return
        recording_active = True
        session_id += 1
        my_session = session_id
        parec_proc = subprocess.Popen(
            ["parec", "--format=s16le", f"--rate={SAMPLE_RATE}", "--channels=1"],
            stdout=subprocess.PIPE
        )
    osd("* REC *", persistent=True)

    def _record():
        import select
        speech_chunks = []
        speech_duration = 0.0
        silence_duration = 0.0
        chunk_duration = 4096 / 2 / SAMPLE_RATE

        def _flush_transcription():
            nonlocal speech_chunks, speech_duration, silence_duration
            if speech_duration >= MIN_SPEECH_SECONDS:
                data_to_transcribe = b"".join(speech_chunks)
                threading.Thread(target=transcribe,
                                 args=(data_to_transcribe, my_session),
                                 daemon=True).start()
            speech_chunks = []
            speech_duration = 0.0
            silence_duration = 0.0

        while True:
            with recording_lock:
                if not recording_active or session_id != my_session:
                    return  # stopped or new session — discard, no transcription
                proc = parec_proc

            r, _, _ = select.select([proc.stdout], [], [], 0.1)
            if not r:
                continue
            data = proc.stdout.read(4096)
            if not data:
                if proc.poll() is not None:
                    print(f"parec exited with code {proc.returncode}", file=sys.stderr, flush=True)
                    osd("parec failed!")
                    return
                continue

            level = rms(data)
            if level > SILENCE_RMS:
                speech_chunks.append(data)
                speech_duration += chunk_duration
                silence_duration = 0.0
                if speech_duration >= MAX_SPEECH_SECONDS:
                    _flush_transcription()
            else:
                speech_chunks.append(data)
                silence_duration += chunk_duration
                if silence_duration >= SILENCE_SECONDS:
                    _flush_transcription()

    threading.Thread(target=_record, daemon=True).start()

def stop_recording():
    global parec_proc, recording_active, session_id
    with recording_lock:
        if parec_proc is None:
            return
        recording_active = False
        session_id += 1  # invalidates all in-flight transcriptions
        parec_proc.terminate()
        parec_proc.wait()
        parec_proc = None
    osd(None)

# ── Main ──────────────────────────────────────────────────────────────────────

def main():
    global _use_openvino, _ov_model, _ov_processor, model

    # ── Model loading ─────────────────────────────────────────────────────────
    print(f"Loading model {MODEL_NAME}...", flush=True)
    from faster_whisper import WhisperModel
    if os.path.isdir(OV_MODEL_DIR) and any(f.endswith(".xml") for f in os.listdir(OV_MODEL_DIR)):
        _device_label = "iGPU"
        osd(f"loading on {_device_label}...", persistent=True)
        print("Loading pre-converted OpenVINO model on GPU...", flush=True)
        from optimum.intel import OVModelForSpeechSeq2Seq
        from transformers import AutoProcessor
        _ov_model = OVModelForSpeechSeq2Seq.from_pretrained(OV_MODEL_DIR, device="GPU")
        _ov_processor = AutoProcessor.from_pretrained(OV_MODEL_DIR)
        _use_openvino = True
    else:
        _device_label = "CPU"
        osd(f"loading on {_device_label}...", persistent=True)
        print("No OpenVINO model found, using faster-whisper on CPU...", flush=True)
        model = WhisperModel(MODEL_NAME, device="cpu", compute_type="int8")
    print(f"Model loaded on {_device_label}. Ready.", flush=True)
    osd(None)

    # ── Socket server ─────────────────────────────────────────────────────────
    if os.path.exists(SOCKET_PATH):
        os.unlink(SOCKET_PATH)

    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(SOCKET_PATH)
    os.chmod(SOCKET_PATH, 0o600)
    server.listen(1)

    def handle_signals(sig, frame):
        stop_recording()
        server.close()
        if os.path.exists(SOCKET_PATH):
            os.unlink(SOCKET_PATH)
        sys.exit(0)

    signal.signal(signal.SIGTERM, handle_signals)
    signal.signal(signal.SIGINT, handle_signals)

    # Start recording immediately — daemon is launched on first keypress
    start_recording()

    while True:
        try:
            conn, _ = server.accept()
            cmd = conn.recv(16).decode().strip()
            conn.close()
            if cmd == "start":
                threading.Thread(target=start_recording, daemon=True).start()
            elif cmd == "stop":
                threading.Thread(target=stop_recording, daemon=True).start()
        except OSError:
            break

if __name__ == "__main__":
    main()

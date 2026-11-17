#!/usr/bin/env python3
"""Fetches the speaker-evaluation set for `hearsay --eval-speakers` (see docs/EVAL-SPEAKERS.md).

AMI Meeting Corpus (CC BY 4.0), single distant microphone (Array1-01: one mic in the middle of the
table, four people around it, the shared-MacBook case) plus the manual word-level annotations.
Each meeting is trimmed to a fixed 10-minute window and written as

    <out>/<meeting>.wav          16 kHz mono 16-bit PCM, peak-normalised
    <out>/<meeting>.words.tsv    start<TAB>end<TAB>speaker<TAB>word   (seconds into the trimmed wav)

Usage: python3 -I scripts/ami-eval-prep.py OUT_DIR   (downloads ~290 MB once into OUT_DIR/raw)
Standard library + curl.
"""
import array
import os
import subprocess
import sys
import wave
import xml.etree.ElementTree as ET
import zipfile

# Fixed for reproducibility: AMI full-corpus test meetings, all four speakers present, a mix of
# the scenario (ES, IS, TS) and the free-discussion (EN) sets.
MEETINGS = ["ES2004a", "ES2014a", "IS1009a", "TS3003a", "TS3007a", "EN2002a"]
# Skip the first minute (microphone checks, people sitting down), keep ten.
START, LENGTH = 60.0, 600.0

AUDIO = "https://groups.inf.ed.ac.uk/ami/AMICorpusMirror/amicorpus/{m}/audio/{m}.Array1-01.wav"
ANNOTATIONS = "https://groups.inf.ed.ac.uk/ami/AMICorpusAnnotations/ami_public_manual_1.6.2.zip"


def fetch(url, path):
    if os.path.exists(path):
        return
    print("downloading", url, file=sys.stderr)
    tmp = path + ".partial"
    # curl, not urllib: python.org builds often lack a CA bundle; curl uses the system's.
    subprocess.run(["curl", "-fL", "--retry", "3", "-o", tmp, url], check=True)
    os.replace(tmp, path)


def trim(src, dst):
    with wave.open(src, "rb") as w:
        assert w.getframerate() == 16000 and w.getnchannels() == 1 and w.getsampwidth() == 2, src
        w.setpos(int(START * 16000))
        frames = w.readframes(int(LENGTH * 16000))
    # Peak-normalise to -1 dBFS. The array mic records far below a MacBook microphone (speech
    # around -50 dBFS RMS, under hearsay's -44 dBFS voice gate, so every word would read as
    # silence); a laptop's input gain puts the same room at roughly -35..-25 dBFS.
    pcm = array.array("h", frames)
    if sys.byteorder == "big":
        pcm.byteswap()
    peak = max(1, max(abs(x) for x in pcm))
    gain = 32767 * 10 ** (-1 / 20) / peak
    pcm = array.array("h", (max(-32768, min(32767, int(x * gain))) for x in pcm))
    if sys.byteorder == "big":
        pcm.byteswap()
    frames = pcm.tobytes()
    with wave.open(dst, "wb") as o:
        o.setnchannels(1)
        o.setsampwidth(2)
        o.setframerate(16000)
        o.writeframes(frames)


def words(zf, meeting):
    out = []
    for spk in "ABCDE":
        name = f"words/{meeting}.{spk}.words.xml"
        if name not in zf.namelist():
            continue
        root = ET.fromstring(zf.read(name))
        for w in root.iter("w"):
            if w.get("punc") == "true" or w.get("starttime") is None or w.get("endtime") is None:
                continue
            s, e = float(w.get("starttime")), float(w.get("endtime"))
            text = (w.text or "").strip()
            # Words cut by the window edges are dropped: their audio is only partly there.
            if not text or s < START or e > START + LENGTH:
                continue
            out.append((s - START, e - START, spk, text))
    out.sort()
    return out


def main():
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        sys.exit(2)
    out = sys.argv[1]
    raw = os.path.join(out, "raw")
    os.makedirs(raw, exist_ok=True)
    zpath = os.path.join(raw, "ami_public_manual_1.6.2.zip")
    fetch(ANNOTATIONS, zpath)
    with zipfile.ZipFile(zpath) as zf:
        for m in MEETINGS:
            src = os.path.join(raw, f"{m}.Array1-01.wav")
            fetch(AUDIO.format(m=m), src)
            trim(src, os.path.join(out, f"{m}.wav"))
            ws = words(zf, m)
            with open(os.path.join(out, f"{m}.words.tsv"), "w") as f:
                for s, e, spk, t in ws:
                    f.write(f"{s:.3f}\t{e:.3f}\t{spk}\t{t}\n")
            print(f"{m}: {LENGTH:.0f} s, {len(ws)} words, speakers {''.join(sorted({w[2] for w in ws}))}")


if __name__ == "__main__":
    main()

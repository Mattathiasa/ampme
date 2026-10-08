"""Writes a mono 16-bit 44.1 kHz WAV sine tone for end-to-end tests.

Usage: python3 make_tone.py OUT.wav [SECONDS] [HZ]
"""
import math
import struct
import sys
import wave

out = sys.argv[1]
seconds = int(sys.argv[2]) if len(sys.argv) > 2 else 120
hz = float(sys.argv[3]) if len(sys.argv) > 3 else 440.0
rate = 44100

with wave.open(out, "wb") as w:
    w.setnchannels(1)
    w.setsampwidth(2)
    w.setframerate(rate)
    w.writeframes(
        b"".join(
            struct.pack("<h", int(12000 * math.sin(2 * math.pi * hz * i / rate)))
            for i in range(rate * seconds)
        )
    )

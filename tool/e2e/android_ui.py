"""Finds a node in a `uiautomator dump` (XML on stdin) and prints the center
of its bounds as "x y", for `adb shell input tap`. Exits 1 if not found.

Usage: adb shell cat /sdcard/ui.xml | python3 android_ui.py PATTERN
  PATTERN is a regex matched against each node's text and content-desc
  (Flutter exposes widget semantics as content-desc), or `class:NAME` to
  match the node class (e.g. class:android.widget.EditText).
"""
import re
import sys
import xml.etree.ElementTree as ET

pattern = sys.argv[1]
raw = sys.stdin.read()
start = raw.find("<?xml")
if start < 0:
    sys.exit(1)
root = ET.fromstring(raw[start:raw.rfind(">") + 1])

for node in root.iter("node"):
    if pattern.startswith("class:"):
        hit = node.get("class") == pattern[len("class:"):]
    else:
        rx = re.compile(pattern, re.S)
        hit = any(rx.search(node.get(k) or "") for k in ("text", "content-desc"))
    if not hit:
        continue
    m = re.match(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]", node.get("bounds", ""))
    if not m:
        continue
    x1, y1, x2, y2 = map(int, m.groups())
    print(f"{(x1 + x2) // 2} {(y1 + y2) // 2}")
    sys.exit(0)
sys.exit(1)

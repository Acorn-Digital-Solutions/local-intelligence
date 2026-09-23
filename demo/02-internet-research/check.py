#!/usr/bin/env python3
"""Check for demo 02. Verifies answers.md names the three live-web facts."""
import sys

try:
    with open("answers.md", encoding="utf-8") as f:
        text = f.read()
except OSError as e:
    sys.exit(f"answers BAD: cannot read answers.md: {e}")

low = text.lower()
checks = [
    ("Example Domain" in text, "page title 'Example Domain'"),
    ("Yours Truly" in text, "slideshow author 'Yours Truly'"),
    ("°c" in low or "celsius" in low, "temperature unit (Celsius)"),
    ("example.com" in low, "source URL example.com"),
    ("httpbin.org" in low, "source URL httpbin.org"),
    ("open-meteo.com" in low, "source URL open-meteo.com"),
]
missing = [label for ok, label in checks if not ok]
if missing:
    sys.exit(f"answers BAD, missing: {', '.join(missing)}")
print("answers OK")

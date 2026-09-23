#!/usr/bin/env python3
"""Check for demo 03. Verifies answers.md names the three book characters."""
import sys

try:
    with open("answers.md", encoding="utf-8") as f:
        text = f.read()
except OSError as e:
    sys.exit(f"answers BAD: cannot read answers.md: {e}")

low = text.lower()
checks = [
    ("rabbit" in low, "the Rabbit"),
    ("caterpillar" in low, "the Caterpillar"),
    ("knave" in low, "the Knave of Hearts"),
    (len(text.split()) >= 60, "at least 60 words of answers with sources"),
]
missing = [label for ok, label in checks if not ok]
if missing:
    sys.exit(f"answers BAD, missing: {', '.join(missing)}")
print("answers OK")

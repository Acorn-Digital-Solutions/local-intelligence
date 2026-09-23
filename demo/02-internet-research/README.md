# Demo 02 — internet research (no coding)

Tests working with live web data: fetch pages, extract facts, cite sources.
No code to write — the deliverable is a Markdown file. Needs the internet.

Try it (from this directory):

```bash
opencode run -m ollama/qwen3-coder:30b "complete the TASK in TASK.md"
# or manually: curl the three URLs, write answers.md, then:
python3 check.py
```

Pass = `answers.md` names the page title, the slideshow author and the
temperature unit, each with its source URL (verified by `check.py`).

# Demo tasks — sample projects for testing models and environment

Only the first task involves code. The other two test working with the
world (live web) and with words (long text) — no programming required.

| demo | tests | how to run |
|---|---|---|
| `01-coding-bob` | code from spec + test loop | `opencode run -m ollama/qwen3-coder:30b "implement bob.py so all tests pass"`, then `../../.venv/bin/python -m pytest bob_test.py -q` |
| `02-internet-research` | live-web facts + citations, no code | answer TASK.md into `answers.md` (curl, browser, or agent web tools), then `python3 check.py` |
| `03-text-alice` | RAG over a 151KB book, no code | ingest + `--query` per TASK.md, write `answers.md`, then `python3 check.py` |

Sources: 01 from `exercism/python` (MIT); 02 uses live example.com, httpbin.org
and Open-Meteo; 03 uses Project Gutenberg's Alice in Wonderland (public domain).

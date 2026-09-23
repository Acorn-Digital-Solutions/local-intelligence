# Demo 03 — long-text Q&A with RAG (no coding)

Tests reading a document too big for the model's context (151KB — Alice in
Wonderland, public domain, `alice.txt`) by retrieving instead of pasting.
No code to write — the deliverable is a Markdown file.

Try it (from the repo root, services up):

```bash
.venv/bin/python rag_demo.py --corpus demo/03-text-alice --pattern '*.txt' --collection alice --ingest
.venv/bin/python rag_demo.py --collection alice --query "who chases Alice at the start?"
```

Then answer the three questions in TASK.md into `answers.md` (noting which
retrieved chunk each answer came from) and run `python3 check.py`.

Or agentic: `opencode run -m ollama/qwen3-coder:30b "complete the TASK in demo/03-text-alice/TASK.md"`.

Pass = all three answers name the right characters, grounded in retrieved chunks.

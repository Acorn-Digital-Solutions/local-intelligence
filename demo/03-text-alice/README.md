# Demo 03 — long-text Q&A by direct reading (no coding)

Tests reading a document too big to paste in one go (151KB — Alice in
Wonderland, public domain, `alice.txt`) by paging through it with the
agent's read/grep tools. No code to write, no extra services — the
deliverable is a Markdown file.

Try it (from the repo root, Ollama up):

```bash
grep -n -i "rabbit" demo/03-text-alice/alice.txt | head
sed -n '1,60p' demo/03-text-alice/alice.txt
```

Then answer the three questions in TASK.md into `answers.md` (citing
file:line for each answer) and run `python3 check.py`.

Or agentic: `opencode run -m ollama/muse-glimmer:30b-mlx "complete the TASK in demo/03-text-alice/TASK.md"`.

Pass = all three answers name the right characters, grounded in cited lines.

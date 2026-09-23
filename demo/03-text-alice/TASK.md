# Demo 03 — task (answer from a book too big to paste)

`alice.txt` (151KB) does not fit in a local model's context window, so read
it through retrieval, not by pasting. No programming required.

1. Ingest (repo root, services up):
   `.venv/bin/python rag_demo.py --corpus demo/03-text-alice --pattern '*.txt' --collection alice --ingest`
2. Ask, e.g.: `--collection alice --query "who chases Alice at the start?"`
3. Write `answers.md` answering:
   a. Who chases Alice at the start of the book?
   b. Who is smoking on a mushroom, and what?
   c. Who is accused of stealing the tarts?
   For each answer, note the source chunk it came from.
4. Verify with `python3 check.py` — it must print `answers OK`.

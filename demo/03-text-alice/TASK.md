# Demo 03 — task (answer from a book too big to paste in one go)

`demo/03-text-alice/alice.txt` (151KB, ~40K tokens) fits in the model's
131K context but exceeds a single agent step — page through it with
reads/grep instead of pasting. No programming required. No extra
services: only Ollama needs to be up.

1. From the repo root, locate `demo/03-text-alice/alice.txt`.
2. Read it in chunks (e.g. `read_file_range`, `sed -n`) and use `grep`
   to pinpoint the scenes. Do NOT paste the whole file into one message.
3. Write `demo/03-text-alice/answers.md` answering:
   a. Who chases Alice at the start of the book?
   b. Who is smoking on a mushroom, and what?
   c. Who is accused of stealing the tarts?
   For each answer, cite the file and line number it came from.
4. Verify with `(cd demo/03-text-alice && python3 check.py)` — it must
   print `answers OK`.

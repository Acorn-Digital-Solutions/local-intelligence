# Demo 01 — coding exercise (Bob)

Tests the agent's ability to write code from a spec and satisfy tests.

Source: `exercism/python` practice exercise "bob" (MIT-licensed track).
`bob.py` is the stub to implement; `bob_test.py` (unittest, ~20 cases) is the grader.

Bob's rules: answer "Sure." to questions, "Whoa, chill out!" to shouting,
"Calm down, I know what I'm doing!" to shouted questions, "Fine. Be that
way!" to silence, "Whatever." to anything else.

Try it (from this directory):

```bash
opencode run -m ollama/muse-glimmer:30b-mlx "implement bob.py so all tests pass"
../../.venv/bin/python -m pytest bob_test.py -q
```

Pass = agent loop (read spec, edit, run tests) works end to end on local models.

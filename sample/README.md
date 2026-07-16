# allisp samples

Each file is standalone and demonstrates one evaluation path.

| File | Evaluation path |
|---|---|
| `01-deterministic.lisp` | Defined functions and builtins only. No LLM call. |
| `02-llm-oracle.lisp` | An undefined analysis form is pseudo-executed by the LLM oracle. |
| `03-macro-oracle-deterministic.lisp` | Deterministic macro expansion, one LLM value, then deterministic processing. |
| `04-generate-file.lisp` | Evaluates a code-building function and writes the resulting program to another file. |
| `05-solve-deterministic.lisp` | Recursive `goal` rules and deterministic `solve` deduction. |
| `06-solve-llm-goal.lisp` | One LLM review result is used as input to a deterministic logic goal. |
| `07-solve-constraints.lisp` | `constraint` filters branches after logic variables are bound. |

Inspect the oracle boundary without making an LLM call:

```sh
bin/allisp run sample/01-deterministic.lisp --dry-run
bin/allisp run sample/02-llm-oracle.lisp --dry-run
bin/allisp run sample/03-macro-oracle-deterministic.lisp --dry-run
bin/allisp run sample/04-generate-file.lisp --dry-run
bin/allisp run sample/05-solve-deterministic.lisp --dry-run
bin/allisp run sample/06-solve-llm-goal.lisp --dry-run
bin/allisp run sample/07-solve-constraints.lisp --dry-run
```

Run a sample with the authenticated `claude` CLI:

```sh
bin/allisp run sample/02-llm-oracle.lisp
bin/allisp run sample/03-macro-oracle-deterministic.lisp
bin/allisp run sample/06-solve-llm-goal.lisp
```

Generate and execute a program without an LLM call:

```sh
bin/allisp run sample/04-generate-file.lisp
bin/allisp run sample/output/generated-double.lisp
```

The generated file contains its own `generated-by` macro and provenance
marker. Its generated program defines `double` and evaluates `(double 21)` to
`42`.

Results and oracle traces are written to `sample/output/`.

## Hybrid sample flow

The third sample evaluates in this order:

1. `review-score` expands deterministically into a `let`, `list`, `+`, and
   `get-property` expression.
2. Only the undefined `estimate-risk-adjustment` form is sent to the LLM.
3. The returned plist is bound to `review`.
4. The expanded `get-property`, `+`, and `list` forms run deterministically.

For example, an oracle value of
`(:adjustment -12 :reason "Load testing is still open")` produces a final
score of `58` from the deterministic `(+ 70 -12)` expression.

The oracle returns a value, not executable code. The macro supplies the code
that consumes that value, keeping the final processing deterministic.

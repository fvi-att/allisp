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
| `08-defer-deprecate.lisp` | Preserves a deferred, unevaluated decision and marks an evaluated result as deprecated. |
| `09-executable-adr.lisp` | An executable ADR: premises are `def` data, decisions are oracle forms. Editing one premise re-runs only the dependent decision. |
| `10-generate-markdown.lisp` | Renders structured data into a Markdown report and writes it to a plain `.md` file via `generate-file`. No LLM call. |

Inspect the oracle boundary without making an LLM call:

```sh
bin/allisp run sample/01-deterministic.lisp --dry-run
bin/allisp run sample/02-llm-oracle.lisp --dry-run
bin/allisp run sample/03-macro-oracle-deterministic.lisp --dry-run
bin/allisp run sample/04-generate-file.lisp --dry-run
bin/allisp run sample/05-solve-deterministic.lisp --dry-run
bin/allisp run sample/06-solve-llm-goal.lisp --dry-run
bin/allisp run sample/07-solve-constraints.lisp --dry-run
bin/allisp run sample/08-defer-deprecate.lisp --dry-run
bin/allisp run sample/09-executable-adr.lisp --dry-run
bin/allisp run sample/10-generate-markdown.lisp --dry-run
```

Run a sample with the authenticated `claude` CLI:

```sh
bin/allisp run sample/02-llm-oracle.lisp
bin/allisp run sample/03-macro-oracle-deterministic.lisp
bin/allisp run sample/06-solve-llm-goal.lisp
bin/allisp run sample/09-executable-adr.lisp
```

Generate and execute a program without an LLM call:

```sh
bin/allisp run sample/04-generate-file.lisp
bin/allisp run sample/output/generated-double.lisp
```

The generated file contains its own `generated-by` macro and provenance
marker. Its generated program defines `double` and evaluates `(double 21)` to
`42`.

Generate a Markdown report (no LLM call, no `.lisp` header):

```sh
bin/allisp run sample/10-generate-markdown.lisp
cat sample/output/findings-report.md
```

A `.md` target is not a `.lisp` target, so `generate-file` requires the body
to evaluate to a string and writes it verbatim: no `generated-by` marker, no
S-expression header, since Markdown has no comment syntax to embed one in.

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

## Premise-change replay (executable ADR)

The ninth sample records an architecture decision as three `def` premises and
two oracle decisions. The oracle cache key includes the bindings each form
references, so editing one premise invalidates only the decisions that depend
on it:

```sh
bin/allisp run sample/09-executable-adr.lisp   # first run:  2 misses
bin/allisp run sample/09-executable-adr.lisp   # replay:     2 hits, no LLM call
# edit budget-premise (e.g. 800 → 600), then:
bin/allisp run sample/09-executable-adr.lisp   # 1 miss (decision), 1 hit (revisit-triggers)
```

`decision` references all three premises and is re-thought. `revisit-triggers`
references only `team-premise` and replays from cache. Reverting the premise
restores the original cache entry, so the next run is again 2 hits.

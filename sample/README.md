# allisp samples

Each file is standalone and demonstrates one evaluation path.

| File | Evaluation path |
|---|---|
| `01-deterministic.lisp` | Defined functions and builtins only. No LLM call. |
| `02-llm-oracle.lisp` | An undefined analysis form is lowered to executable Lisp code by the LLM oracle. |
| `03-macro-oracle-deterministic.lisp` | Deterministic macro expansion, one LLM-generated expression, then deterministic processing. |
| `04-generate-file.lisp` | Evaluates a code-building function and writes the resulting program to another file. |
| `05-solve-deterministic.lisp` | Recursive `goal` rules and deterministic `solve` deduction. |
| `06-solve-llm-goal.lisp` | One LLM review result is used as input to a deterministic logic goal. |
| `07-solve-constraints.lisp` | `constraint` filters branches after logic variables are bound. |
| `08-defer-deprecate.lisp` | Preserves a deferred, unevaluated decision and marks an evaluated result as deprecated. |
| `09-executable-adr.lisp` | An executable ADR: premises are `def` data, decisions are oracle forms, and revisit triggers are data conditions the evaluator re-checks deterministically. |
| `10-generate-markdown.lisp` | Renders structured data into a Markdown report and writes it to a plain `.md` file via `generate-file`. No LLM call. |
| `11-markdown-to-lisp.lisp` | The reverse direction: `markdown->lisp` has the oracle convert a markdown runbook into an allisp program (prose forbidden) and writes it to a `.lisp` file. |
| `12-spec-as-source.lisp` | The spec as the formal source of truth: one `def` spec generates a readable doc, a pytest test oracle, and a Python implementation that passes it; a spec query returns `intermediate-code` naming a hole in the invariants. |
| `15-probe.lisp` | `probe-spec` adversarially audits a repaired slugify contract for conflicting clauses and unspecified input regions. |

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
bin/allisp run sample/11-markdown-to-lisp.lisp --dry-run
bin/allisp run sample/12-spec-as-source.lisp --dry-run
```

Run a sample with the authenticated `claude` CLI:

```sh
bin/allisp run sample/02-llm-oracle.lisp
bin/allisp run sample/03-macro-oracle-deterministic.lisp
bin/allisp run sample/06-solve-llm-goal.lisp
bin/allisp run sample/09-executable-adr.lisp
bin/allisp run sample/11-markdown-to-lisp.lisp
bin/allisp run sample/12-spec-as-source.lisp
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

Convert a markdown document into an allisp program (one LLM call, cached):

```sh
bin/allisp run sample/11-markdown-to-lisp.lisp
cat sample/output/deploy-runbook.lisp
```

`markdown->lisp` is the reverse of sample 10: the oracle converts the
document under the anti-prose rules — every step and threshold becomes a
structured S-expression or a small declarative DSL, never a restated string.
The reply is one `(progn ...)` of top-level forms that is kept as a program,
not executed; `:out` writes it with a `generated-by` marker so it can be run
or `@use`'d on its own, and a rerun replays from the oracle cache.

Run the spec-as-source-of-truth loop (4 oracle calls, cached):

```sh
bin/allisp run sample/12-spec-as-source.lisp
python3 -m pytest sample/output/test_slugify.py   # generated impl vs. generated tests
cat sample/output/slugify-spec.md                 # generated readable doc
```

The spec is the only handwritten artifact. The oracle generates the markdown
document, the pytest test oracle, and the implementation (which it writes to
pass the tests it can Read). The final `query-spec` form deliberately asks
about an underspecified corner — an all-punctuation title, where `:collapse`
and `:no-edge-hyphen` conflict — and comes back as `intermediate-code` whose
`:how` names the top-level named `example` or invariant amendment that would
settle it. A rerun replays all
four calls from cache with no LLM call.

A full walkthrough of this workflow (spec structure, form ordering, turning
an `intermediate-code` answer into a spec clause) is in
[docs/spec-driven.md](../docs/spec-driven.md) (Japanese).

Results and oracle traces are written to `sample/output/`.

## Hybrid sample flow

The third sample evaluates in this order:

1. `review-score` expands deterministically into a `let`, `list`, `+`, and
   `get-property` expression.
2. Only the undefined `estimate-risk-adjustment` form is sent to the LLM for code generation.
3. The generated expression is checked, evaluated deterministically, and its plist is bound to `review`.
4. The expanded `get-property`, `+`, and `list` forms run deterministically.

For example, oracle code `(quote (:adjustment -12 :reason "Load testing is
still open"))` produces a final score of `58` from the deterministic
`(+ 70 -12)` expression.

The oracle returns Lisp code. Allisp executes it only when the whole expression
is resolved; otherwise `intermediate-code` retains it for a later lowering
pass. The macro then consumes the evaluated value deterministically.

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

`decision` references the premises it names and is re-thought when one of them
changes. `revisit-triggers` does not reference `budget-premise` and replays
from cache. Reverting the premise restores the original cache entry, so the
next run is again 2 hits.

### Executable revisit triggers

`plan-revisit-triggers` asks the oracle for data conditions, not prose: each
trigger names a metric from `:metrics-available`, a direction
(`at-or-above` / `at-or-below`), and a threshold. That plan is the whole LLM
output surface. The check itself is the deterministic `trigger-fired?`
function, evaluated against the `observed` premise:

```sh
# edit observed (e.g. :peak-orders-per-minute 46 → 85), then:
bin/allisp run sample/09-executable-adr.lisp   # 0 misses — the trigger check
                                               # is pure evaluator work
```

The final form reports `(:revisit-needed t :fired (...))` the moment an
observation crosses a planned threshold. The LLM planned the conditions once;
deciding whether to revisit never costs another LLM call.

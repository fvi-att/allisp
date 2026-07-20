# Allisp

Write the source of truth formally, as S-expressions, instead of natural
language — then let an LLM generate everything derived from it: readable
documents, test oracles, and implementations that must pass them.

Defined forms evaluate deterministically.
For undefined forms, an LLM generates Lisp code but never executes it.
Allisp runs that code only when its deterministic evaluator can resolve the
whole program; otherwise it returns inert `intermediate-code` for another
lowering pass.

```lisp
(defun average (numbers)
  (/ (reduce (lambda (total number) (+ total number))
             numbers :initial-value 0)
     (length numbers)))

(def samples '(12 18 15))

(average samples)                                ; defined → 15

(summarize-metrics :samples samples)             ; undefined → the oracle generates Lisp code
```

The more `defun` and `defmacro` definitions you add, the more of the program evaluates deterministically.
The LLM fills gaps by lowering them to code. It cannot claim that allocation,
file mutation, deployment, message sending, or any other real-world effect
happened. Generated code lands in a persistent cache, so rerunning the same
input re-evaluates the same code deterministically without calling the LLM.

## The spec is the source of truth

A natural-language spec cannot be the canonical record: it drifts, nothing
checks it, and every reader parses it differently. In allisp the spec is a
first-class language object — `defspec` binds named invariant clauses and
examples, schema-checked before anything else runs — and everything a human
or CI consumes is generated from it, never the other way around:

```lisp
(defspec slugify
  :signature (:in (title string) :out (slug string))
  :invariants ((:no-edge-hyphen "the slug never starts or ends with a hyphen") ...))

(example slugify :name :hello-world
  :in "Hello, World!" :out "hello-world"
  :context "Apply the ASCII slug policy to an ordinary title."
  :covers (:no-edge-hyphen))

(check-spec slugify)                       ; invariants + normative contexts
(probe-spec slugify)                       ; full conflict/hole audit
(derive "output/test_slugify.py"           ; test oracle, recorded in the derivation ledger
  :from slugify
  :via (lower-to-pytest :spec slugify :import-from "slugify"))
(derive "output/slugify.py"                ; implementation, generated to pass the tests
  :from slugify
  :via (implement-to-pass :spec slugify :test-file "output/test_slugify.py"
                          :language "python 3, standard library only"))
(verify "python3 -m pytest output/test_slugify.py"
  :targets ("output/test_slugify.py" "output/slugify.py"))
```

- **`example`** appends named, unevaluated examples to a preceding same-file
  `defspec`. Its required natural-language `:context` is normative; optional
  `:covers` and `:depends-on` make traceability and runtime inputs explicit.
- **`check-spec`** lowers invariant clauses and example contexts to reusable
  predicates and applies them deterministically. **`derive` requires both a
  current successful check and a complete, finding-free `probe-spec`.**
- **`derive`** generates the artifact exactly like `generate-file` and records
  spec/example/dependency proof hashes and file hashes in a ledger.
  `--ignore-skip` can accept check skips, but never violations or probe
  findings. **`allisp spec status`** later
  reports each artifact as `fresh`, `stale` (spec edited), or `drifted`
  (artifact hand-edited) with zero LLM calls.
- **`verify`** registers the external test command; `allisp run --verify`
  executes it after generation, and a failing test lands in the result file as
  a first-class error value.
- **`probe-spec`** audits the spec itself: the oracle does not invent answers
  for corners the clauses leave open — it returns findings whose `:why` names
  the conflicting clauses and whose `:how` says which example or invariant
  amendment would settle the hole. Asking a formal model finds the hole that
  prose would have papered over.

Code generation is delegated to the LLM; execution never is. Generated Lisp
runs only under the deterministic evaluator, and generated Python or Markdown
is written out as text for external tools to run. An unchanged spec replays
every artifact from cache, byte-identical, with no LLM call — and the ledger
turns "derived artifacts must not drift" from a discipline into a machine
check. Edit one clause and only the predicates and artifacts that reference
it are re-generated.

```sh
bin/allisp run sample/16-verify-pipeline.lisp --verify --ignore-skip
allisp spec status                                      # every artifact fresh & verified?
bin/allisp run sample/16-verify-pipeline.lisp --verify --ignore-skip  # replay
```

A step-by-step walkthrough — how to structure a spec, check it, order the
derivations, and turn a probe finding back into a spec clause — is in
[docs/spec-driven.md](docs/spec-driven.md) (Japanese). The same workflow
also works without the dedicated syntax, on plain `def` plists and
`generate-file`: [sample/12-spec-as-source.lisp](sample/12-spec-as-source.lisp).

## Judgments no CPU could compute

Until now, a program could only contain functions a CPU can compute.
Judgments like "how risky is this release?" or "can this team operate a message queue?" have no deterministic definition, so they lived outside the program, in documents and meetings.

In allisp, an undefined form is not immediately an error: the whole form goes
to the LLM for code generation. A judgment or estimate becomes executable only
after the generated expression contains no unresolved operation.

```lisp
(classify-release-risk
  :context release-context
  :return-shape '(:risk-level symbol :reasons (string)))
```

The oracle returns code as one S-expression rather than prose. For example,
list data must be emitted as `(quote (:risk-level high ...))` or constructed
with deterministic functions. Allisp verifies the code, executes it with LLM
fallback disabled, and passes the resulting value to deterministic
post-processing such as `get-property` or `filter`.

If a unique executable program cannot yet be generated, the result remains
inert and retains constraints and candidates for a later pass:

```lisp
(intermediate-code
  :source (choose-storage :durable t)
  :reason (:why "the storage backend is not selected"
           :how "select PostgreSQL or SQLite, then run another lowering pass")
  :constraints (:durable t)
  :candidates ((use-postgres) (use-sqlite)))
```

Evaluate `(llm <intermediate-code>)` explicitly when more context is available
and another lowering pass is wanted.

Use `(fix <form>)` to let the oracle choose explicit, inspectable defaults for
one intermediate result. Use `(re-fix <form>)` to repeat that process and
recursively repair intermediate-code nested anywhere in the result value.
Each repaired node retains its source, generated code, and executed value in a
`fixed` record; `:rounds` limits attempts per node (default 16).

During file execution, the oracle explores the repository with read-only tools
and reads the files a form refers to before generating code (disable with
`--no-explore`).

## An ADR you can run

An **ADR** (architecture decision record) stops the moment you write it.
When premises change, the document stays behind, and a person has to reread it to check whether the decision still holds.

In allisp, you write premises as `def` bindings and the decision as an oracle form.
The record itself executes, so a rerun is an audit.
The result and trace record, as S-expressions, which premises led to which judgments.

The oracle cache key includes the bindings a form references.
Rewrite one premise, and only the expressions that depend on it are re-thought; the rest replay from cache.

[sample/09-executable-adr.lisp](sample/09-executable-adr.lisp) is a minimal ADR with three premises and two judgments.
Rewrite only the budget premise and rerun: the budget-dependent decision goes back to the oracle, while the revisit triggers, which read only the team premise, come back from cache.

```sh
bin/allisp run sample/09-executable-adr.lisp   # first run: oracle 2 calls (2 misses)
bin/allisp run sample/09-executable-adr.lisp   # rerun: 2 hits, no LLM call
# rewrite budget-premise and rerun: 1 miss / 1 hit
```

## Compared with prompts in Markdown

Many teams keep LLM instructions in Markdown documents and paste them into a chat whenever needed.
That workflow keeps no record of execution.
Each rerun bills you again, answers a bit differently, and leaves no way to match an instruction version to the answer it produced.

In allisp, an LLM call is an expression in the language, and each run leaves two records.

- **trace**: a record of every oracle call, including generated code, whether
  it was executed or retained as intermediate code, and its resulting value.
- **oracle cache**: persisted under `.allisp/oracle/`, keyed by the sha256 of
  the prompt version, the model, and the full prompt text. It stores generated
  code, not a claim that an effect occurred.

Rerunning the same input calls no API and returns identical values.
Cost and variance disappear exactly as far as this replay reaches.
When you want fresh thinking, break the cache with `--refresh` or `(llm :fresh t)`.
Keep the cache in Git, and you version the model's answers themselves.

## Publishing and use

This repository excludes personal settings, IDE settings, oracle caches, and execution results.
`.gitignore` covers them; generated files can contain your inputs and local paths, so review them before publishing.
The license is the [GNU General Public License v3.0](LICENSE) (GPL-3.0-only).

- Language spec (execution boundary, `llm`, `pure`, `@use`, error values, cache): [docs/language.md](docs/language.md) (Japanese)
- Spec-driven generation guide (spec as the source of truth → docs / tests / implementation): [docs/spec-driven.md](docs/spec-driven.md) (Japanese)
- Development guide (tests, source layout, swapping backends): [docs/development.md](docs/development.md) (Japanese)
- Design decision history: [DESIGN.md](DESIGN.md) (Japanese)
- Samples mixing determinism, LLM calls, and macros: [sample/README.md](sample/README.md)

## Usage

The samples in this repository depend on no external allisp sources.
The following dry-run executes without calling the LLM.

```sh
bin/allisp run sample/01-deterministic.lisp --dry-run
```

```sh
allisp run <file.lisp>               # run a file
allisp run <dir>                     # run every top-level *.lisp in <dir>, filename order (non-recursive)
allisp run <file.lisp> --dry-run     # show what would reach the oracle, without calling the LLM
allisp run <file.lisp> --refresh     # ignore the cache and re-run every oracle call
allisp run <file.lisp> --strict      # stop at the first error (default: errors become values, execution continues)
allisp run <file.lisp> --backend codex  # use the authenticated Codex CLI oracle
allisp run <file.lisp> --model opus  # change the default model (sonnet | opus | haiku)
allisp run <file.lisp> --no-explore  # disable the oracle's repository exploration (Read/Glob/Grep)
allisp run <file.lisp> --out-dir results/  # write result/trace files under results/ instead of output/
allisp run <file.lisp> --verify      # after evaluation, run registered (verify ...) commands (external tests)
allisp --one-liner "(+ 1 2)"         # evaluate the forms in the string and print the last value
allisp run thought.lisp --plugin 'https://example.com/review-syntax.git#<commit-sha>'
allisp diff old.result.lisp new.result.lisp  # which premises changed, and which conclusions changed with them
allisp spec status                   # freshness of every derived artifact (fresh | stale | drifted | ...)
```

`--one-liner` accepts multiple forms.
It evaluates them in order and prints only the last value to stdout as an S-expression.
It writes no files and uses the current project's `.allisp/oracle/` as the LLM cache.
`--dry-run`, `--refresh`, `--strict`, `--backend`, and `--model` combine with it.

`allisp diff` compares two result files without any LLM call: `def`-family
results match by defined name, other results match by form, and each differing
value prints as one `(changed ...)` / `(added ...)` / `(removed ...)`
S-expression. Edit one premise, re-run, and diff the old and new result files
to see exactly which conclusions that premise carried. Exit code 0 means
identical, 1 means they differ.

`--backend` accepts `claude` (the default) or `codex`.  The Claude backend
uses the authenticated `claude` CLI and defaults to `sonnet`; the Codex backend
uses `codex exec` in its read-only sandbox and defaults to `gpt-5.6-terra`.
Pass `--model <model-id>` to choose a different model for either backend.

## Chaining results

A result file can feed the next run through `@use`.
Names bound with `def` upstream are restored just by loading the result file (no LLM call).

```lisp
;; upstream plan.lisp
(def CONCLUSION (plan_dsl ...))

;; downstream — lower the abstract DSL conclusion to Python
(@use "./output/plan.result.lisp")
(generate-file "generated/review.py"
  (lower-to-python CONCLUSION))   ; an LLM-generated string literal evaluates to raw Python
```

When the target is not a `.lisp` file, `generate-file` writes the string value as raw text.
`last-result` refers to the most recent result value.
See "result chaining" in the [language spec](docs/language.md) for details.

## Generating code from evaluated values

The **`generate-file` macro** writes the final value of its body to another file as one toplevel S-expression.

```lisp
(generate-file "generated/add-two.lisp"
  (synthesize-adder :increment 2))  ; undefined, so the LLM generates quoted code
```

Relative output paths resolve against the calling file.
When the LLM generates `(quote (defun add-two (x) (+ x 2)))`, deterministic
evaluation produces the `defun` as data and `generated/add-two.lisp` receives
three forms:

1. the definition of the `generated-by` macro
2. a `generated-by` call recording the source, the original form, and the generation time
3. `(defun add-two (x) (+ x 2))`

Evaluating the generated file binds the generation record to `*generated-by*` as a plist.
`--dry-run` prints the evaluation boundary and the planned output path, and creates no file.

## Input and output

**Input**: one `.lisp` file in allisp form, or a directory.
Each toplevel S-expression evaluates in order from the top.
`(@use "relative/path")` inherits the definitions of another file.
A directory runs every top-level `*.lisp` file it contains (non-recursive,
filename order, generated `*.result.lisp`/`*.trace.lisp` excluded) as
independent runs sharing no environment. Without `--strict`, a failing file
is recorded and the rest still run; with `--strict`, the first failing file
aborts the remaining ones too. The process exit code is `1` if any file failed.

**Output**: two files under `output/` next to the input file (`--out-dir <dir>` redirects them to `<dir>`; in directory mode, `<dir>` is shared by every file).

```
your_folder/
├── bar.lisp                  # input
└── output/
    ├── bar.result.lisp       # evaluated results of all toplevel forms (result :n K :form … :value …)
    └── bar.trace.lisp        # record of all oracle calls (hash / model / hit or miss / value)
```

The oracle cache accumulates under `.allisp/oracle/` at the project root.
This cache is what makes reruns replay deterministically.
See the [language spec](docs/language.md) for details.
The root is the nearest directory above the input file containing `.allisp/` or `.git/`.
If neither exists, the input file's directory is used.

**Exit codes**: `0` no errors, `1` an error value or a `--strict` stop, `2` usage error, `3` internal error.

## Build

You need the following environment.

- [Roswell](https://github.com/roswell/roswell) (manages SBCL).
  Install with `brew install roswell`.
- The [Claude Code](https://claude.com/claude-code) CLI (drives the LLM oracle).
  Authenticate it beforehand.
- Libraries (ironclad, fiveam).
  Quicklisp fetches them on first run.

```sh
cd /path/to/allisp
make test      # run the test suite
make install   # symlink bin/allisp into ~/.local/bin/allisp
make build     # build dist/allisp, a single executable with dependencies included
make clean     # remove dist/
```

- **`bin/allisp`**: a Roswell script.
  Source changes take effect on the next run, so it suits daily use.
- **`dist/allisp`**: a `save-lisp-and-die` image.
  A self-contained binary that needs neither Roswell nor Quicklisp.
  Rebuild with `make build` after changes.

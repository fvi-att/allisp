;; The whole spec-driven pipeline in one file:
;;
;;   defspec      the only handwritten artifact
;;   check-spec   invariants x examples, before anything is derived
;;   derive x3    readable doc, pytest test oracle, implementation + ledger
;;   verify       the external test run, registered for --verify
;;
;;   bin/allisp run sample/16-verify-pipeline.lisp --verify
;;   python3 -m pytest sample/output/test_clamp.py   ; what --verify just ran
;;   bin/allisp spec status                          ; fresh & verified?
;;   bin/allisp run sample/16-verify-pipeline.lisp --verify   ; replay: no LLM call
;;
;; Without --verify the verify form stays (verification ... :status :pending):
;; the evaluator never executes external code on its own. With --verify the
;; runner executes it after every file is generated; a failing pytest becomes
;; a first-class (error :type :verification-failed ...) value in the result
;; file, and on success the ledger entries for :targets are stamped verified.

;; Same clauses as sample/13 — check-spec's per-clause cache entries are
;; shared between the two files.
(defspec clamp
  :signature (:in (x number) (low number) (high number) :out (y number))
  :invariants
  ((:within-bounds "the output is between low and high inclusive")
   (:identity-inside "when x is already between low and high inclusive, the output equals x")
   (:idempotent "clamp(clamp(x, low, high), low, high) equals clamp(x, low, high)"))
  :examples
  ((:in (5 0 10) :out 5)
   (:in (-3 0 10) :out 0)
   (:in (99 0 10) :out 10)))

;; Gate: contradictions between clauses and examples stop the pipeline here,
;; before any artifact is generated. :idempotent is undecidable per example
;; pair (it lands under :skipped) — the generated pytest below covers it.
(check-spec clamp)

;; 1. Readable document — generated from the spec, never written by hand.
(derive "output/clamp-spec.md"
  :from clamp
  :via (document-spec
         :spec clamp
         :audience "a developer implementing or reviewing clamp"
         :format "markdown with an Invariants section and an Examples table"))

;; 2. Test oracle — examples become assertions, invariants become property
;;    checks (including :idempotent, which check-spec could not decide).
(derive "output/test_clamp.py"
  :from clamp
  :via (lower-to-pytest :spec clamp :import-from "clamp"))

;; 3. Implementation — generated to pass the test oracle above; the oracle
;;    can Read the generated test file before writing it.
(derive "output/clamp.py"
  :from clamp
  :via (implement-to-pass
         :spec clamp
         :test-file "output/test_clamp.py"
         :language "python 3, standard library only"))

;; 4. The external check, in the pipeline. Registration is inert; execution
;;    happens only under `allisp run --verify`, cwd = this file's directory.
(verify "python3 -m pytest output/test_clamp.py"
  :targets ("output/test_clamp.py" "output/clamp.py"))

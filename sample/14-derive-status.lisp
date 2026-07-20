;; derive = generate-file plus a derivation ledger entry. Writing behaves
;; exactly like generate-file (same oracle lowering, same cache, same
;; non-.lisp raw-string rule); in addition the ledger at
;; <project-root>/.allisp/derive.lisp records which spec (clause hash)
;; produced which file (byte hash).
;;
;;   bin/allisp run sample/14-derive-status.lisp   ; 1 oracle call, cached
;;   bin/allisp spec status                        ; -> (fresh :target ...)
;;
;; `spec status` never calls the LLM: a defspec's clauses are unevaluated
;; data, so their current hash is recomputed by re-reading this file. Try:
;;
;;   - edit one invariant sentence below, then `bin/allisp spec status`
;;       -> (stale :target ... :from greeting)   ; spec changed, artifact didn't
;;   - rerun this file to regenerate, status is fresh again
;;   - append a line to sample/output/greeting-spec.md, then status
;;       -> (drifted :target ...)                ; artifact edited by hand
;;   - rerun this file (spec unchanged: the cache replays the same bytes)
;;       -> fresh again — the hand edit is gone, which is the point:
;;          fixes belong in the spec, not in the derived file.

(defspec greeting
  :signature (:in (name string) :out (message string))
  :invariants
  ((:begins-hello "the message begins with the word Hello")
   (:contains-name "the message contains the input name verbatim"))
  :examples
  ((:in "Ada" :out "Hello, Ada!")))

(derive "output/greeting-spec.md"
  :from greeting
  :via (document-spec
         :spec greeting
         :audience "a developer implementing or reviewing greeting"
         :format "markdown with an Invariants section and an Examples table"))

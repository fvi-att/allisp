;; A first-class spec. defspec checks the clause schema deterministically
;; (duplicate clause names, malformed invariants or examples are error values
;; and nothing is bound), binds the spec as a plain plist value, and
;; check-spec turns each invariant clause into a predicate applied to every
;; example.
;;
;;   bin/allisp run sample/13-defspec-check.lisp   ; one oracle call per
;;                                                 ; checkable invariant, cached
;;
;; check-spec's cache is per clause: the predicate prompt contains only that
;; clause and the signature. Edit one invariant and only its predicate is
;; re-lowered; add or edit an example and the recheck costs no LLM call.

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

;; Zero-cost reads over the bound spec (no oracle call).
(pure (spec-invariants clamp))
(pure (spec-invariant clamp :within-bounds))
(pure (spec-examples clamp))

;; Each checkable invariant lowers to one (lambda (in out) ...) predicate,
;; cached per clause, and runs against all examples deterministically.
;; :idempotent cannot be decided from a single (in out) pair, so it comes
;; back as intermediate-code and lands under :skipped instead of being
;; approximated by a weaker check — sample/16 hands that clause to pytest.
(check-spec clamp)

;; To see a violation, add this invariant to the spec and rerun: it
;; contradicts the (:in (99 0 10) :out 10) example, and check-spec names
;; both the clause and the example:
;;
;;   (:below-high "the output is strictly less than high")
;;
;; The check-spec value then becomes
;;   (error :type :spec-violation
;;          :detail (spec-check ... :violations
;;                    ((:invariant :below-high :example (:in (99 0 10) :out 10)))))
;; and the run exits non-zero — the contradiction is caught before any
;; artifact is derived from the spec.

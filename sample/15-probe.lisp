;; probe-spec = the active hole detector, the generalization of asking one
;; query-spec question (sample/12). The oracle audits the spec for pairs of
;; invariant clauses that conflict on some input and for regions no clause or
;; example determines. It does not invent answers: each hole comes back as an
;; inert intermediate-code finding whose :why names the clauses in tension
;; and whose :how states the :examples entry that would settle it.
;;
;;   bin/allisp run sample/15-probe.lisp   ; 1 oracle call, cached
;;
;; This spec deliberately keeps the hole sample/12 asks about: for an
;; all-punctuation title, :collapse (everything becomes one hyphen) and
;; :no-edge-hyphen (no hyphen at the edges) cannot both hold. Follow a
;; finding's :how — add the example it names — and that finding disappears
;; from the next audit. The audit prompt contains the whole spec, so any
;; clause edit re-runs it: holes live in the combination of clauses, which
;; is why probe-spec is cached per spec while check-spec is cached per clause.

(defspec slugify
  :signature (:in (title string) :out (slug string))
  :invariants
  ((:only-chars "the slug contains only lowercase ascii letters, digits, and single hyphens")
   (:no-edge-hyphen "the slug never starts or ends with a hyphen")
   (:collapse "every maximal run of non-alphanumeric characters becomes one hyphen"))
  :examples
  ((:in "Hello, World!" :out "hello-world")
   (:in "v2.0 (beta)" :out "v2-0-beta")))

(fix (fix(probe-spec slugify)))

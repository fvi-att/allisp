;; probe-spec = the active hole detector, the generalization of asking one
;; query-spec question (sample/12). The oracle audits the spec for pairs of
;; invariant clauses that conflict on some input and for regions no clause or
;; example determines. It does not invent answers: each hole comes back as an
;; inert intermediate-code finding whose :why names the clauses in tension
;; and whose :how states the example or invariant amendment that would settle
;; it.
;;
;;   bin/allisp run sample/15-probe.lisp   ; one audit call, then cached
;;
;; The earlier version of this sample said every non-alphanumeric run becomes
;; one hyphen while also forbidding edge hyphens. For "!!!" those clauses were
;; contradictory, and adding an example could not repair them. The clauses
;; below resolve the conflict in the specification itself: internal separator
;; runs become one hyphen, edge runs are discarded, and an input with no ASCII
;; alphanumeric characters has the explicitly legal empty output. probe-spec
;; now checks that repaired contract for any remaining holes.

(defspec slugify
  :signature (:in (title string) :out (slug string))
  :invariants
  ((:character-policy
    "ASCII digits are copied unchanged, ASCII letters are copied in lowercase, and every other input character is a separator")
   (:internal-separators
    "every maximal separator run between ASCII alphanumeric runs becomes one hyphen")
   (:edge-separators
    "leading and trailing separator runs are discarded")
   (:empty-output
    "the output is empty if and only if the input contains no ASCII alphanumeric characters")
   (:only-chars
    "the output contains only lowercase ASCII letters, digits, and non-consecutive hyphens")
   (:no-edge-hyphen
    "the output never starts or ends with a hyphen")
   (:idempotent
    "slugify applied to an output slug returns that slug unchanged")))

(example slugify :name :hello-world :in "Hello, World!" :out "hello-world"
  :context "Apply the ASCII slug policy to an ordinary title.")
(example slugify :name :version :in "v2.0 (beta)" :out "v2-0-beta"
  :context "Apply the ASCII slug policy to an ordinary title.")
(example slugify :name :punctuation-only :in "!!!" :out ""
  :context "An input without ASCII alphanumeric characters has empty output."
  :covers (:empty-output :edge-separators))
(example slugify :name :empty :in "" :out ""
  :context "An input without ASCII alphanumeric characters has empty output."
  :covers (:empty-output))
(example slugify :name :edge-separators :in "--Foo--" :out "foo"
  :context "Leading and trailing separator runs are discarded."
  :covers (:edge-separators))
(example slugify :name :internal-separators :in "A__B" :out "a-b"
  :context "Internal separator runs collapse to one hyphen."
  :covers (:internal-separators))
(example slugify :name :ascii :in "ABC123" :out "abc123"
  :context "ASCII letters lowercase and ASCII digits remain unchanged.")
(example slugify :name :accent-at-edge :in "café" :out "caf"
  :context "Non-ASCII characters are separators, including at an edge.")
(example slugify :name :non-ascii-run :in "aé中b" :out "a-b"
  :context "A non-ASCII run between ASCII runs is one internal separator.")
(example slugify :name :already-slug :in "already-slug" :out "already-slug"
  :context "A valid output slug is unchanged."
  :covers (:idempotent))

(probe-spec slugify)

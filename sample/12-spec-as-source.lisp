;; The spec is the source of truth. This file is the canonical record,
;; written as S-expressions, not natural language. Everything a human or
;; CI consumes is generated FROM it:
;;
;;   readable doc   <- the oracle renders the spec for people
;;   test oracle    <- examples and invariants lowered to pytest
;;   implementation <- generated to pass the test oracle
;;
;; An unchanged spec replays every artifact from cache, byte-identical,
;; with no LLM call. Edit one clause and only the forms that reference it
;; are re-generated. Questions about the spec also go through the oracle
;; against this formal model, never against a prose restatement.
;;
;; Try it:
;;   bin/allisp run sample/12-spec-as-source.lisp     ; 4 oracle calls (cached)
;;   python3 -m pytest sample/output/test_slugify.py  ; impl vs. test oracle
;;   bin/allisp run sample/12-spec-as-source.lisp     ; replay: 4 hits, no LLM

(def slugify-spec
  '(:function slugify
    :module "slugify"
    :signature (:in (title string) :out (slug string))
    :invariants
    ((:only-chars "the slug contains only lowercase ascii letters, digits, and single hyphens")
     (:no-edge-hyphen "the slug never starts or ends with a hyphen")
     (:collapse "every maximal run of non-alphanumeric characters becomes one hyphen")
     (:idempotent "slugify(slugify(x)) equals slugify(x)"))
    :examples
    ((:in "Hello, World!" :out "hello-world")
     (:in "  READY  to   SHIP  " :out "ready-to-ship")
     (:in "v2.0 (beta)" :out "v2-0-beta"))))

;; 1. Readable document — generated from the spec, never written by hand.
(generate-file "output/slugify-spec.md"
  (document-spec
    :spec slugify-spec
    :audience "a developer implementing or reviewing slugify"
    :format "markdown with an Invariants section and an Examples table"))

;; 2. Test oracle — the examples become assertions, the invariants become
;;    property checks over a fixed list of inputs. No test is written by hand.
(generate-file "output/test_slugify.py"
  (lower-to-pytest
    :spec slugify-spec
    :import-from "slugify"))

;; 3. Implementation — generated to pass the test oracle above. The oracle
;;    can Read the generated test file before writing the implementation.
(generate-file "output/slugify.py"
  (implement-to-pass
    :spec slugify-spec
    :test-file "output/test_slugify.py"
    :language "python 3, standard library only"))

;; 4. Querying the spec goes through the formal model, not prose. This
;;    question probes a corner the invariants leave open on purpose: for an
;;    all-punctuation title, :collapse demands a single hyphen while
;;    :no-edge-hyphen forbids it. Asked against prose, an LLM would pick an
;;    answer. Asked against the formal model, the oracle returns
;;    intermediate-code whose :reason names the conflicting clauses and
;;    whose :how says which :examples entry to add to settle it.
(llm
  (query-spec
    :spec slugify-spec
    :question "Is the empty string a legal slug when the title has no alphanumeric characters?"
    :return-shape '(:answer symbol :because string)))

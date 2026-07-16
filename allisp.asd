(defsystem "allisp"
  :description "allisp — a Lisp dialect where defined thought evaluates deterministically and undefined thought is pseudo-executed by an LLM oracle."
  :version "0.1.0"
  :depends-on ("uiop" "ironclad")
  :serial t
  :pathname "src/"
  :components ((:file "package")
               (:file "reader")
               (:file "env")
               (:file "backend")
               (:file "cache")
               (:file "eval")
               (:file "builtins")
               (:file "runner")
               (:file "cli"))
  :in-order-to ((test-op (test-op "allisp/tests"))))

(defsystem "allisp/tests"
  :depends-on ("allisp" "fiveam")
  :pathname "tests/"
  :components ((:file "main"))
  :perform (test-op (o c)
             (declare (ignore o c))
             (uiop:symbol-call :fiveam :run! :allisp)))

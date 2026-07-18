(defsystem "allisp"
  :description "allisp — a staged Lisp dialect where an LLM lowers undefined thought to code and the deterministic evaluator executes only resolved programs."
  :version "0.1.0"
  :depends-on ("uiop" "ironclad")
  :serial t
  :pathname "src/"
  :components ((:file "package")
               (:file "reader")
               (:file "env")
               (:file "backend")
               (:file "cache")
               (:file "plugin")
               (:file "eval")
               (:file "builtins")
               (:file "diff")
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

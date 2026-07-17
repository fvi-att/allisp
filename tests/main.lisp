(defpackage #:allisp/tests
  (:use #:cl #:fiveam))
(in-package #:allisp/tests)

(def-suite :allisp)
(in-suite :allisp)

(defvar *test-random-state* (make-random-state t))

(defun fresh-root ()
  (let ((dir (merge-pathnames
              (format nil "allisp-tests/~36r/"
                      (random most-positive-fixnum *test-random-state*))
              (uiop:temporary-directory))))
    (ensure-directories-exist dir)
    dir))

(defun make-empty-file (path)
  (ensure-directories-exist path)
  (with-open-file (out path :direction :output :if-exists :supersede)
    (declare (ignore out)))
  path)

(defun make-test-run (&key (responses '("42")) root)
  (allisp::make-run :root (or root (fresh-root))
                    :model "sonnet"
                    :backend (make-instance 'allisp::mock-backend
                                            :responses responses)))

(defun ev (string &key (responses '("42")) run)
  "Evaluate all forms in STRING with a mock oracle.
Returns (values last-value run)."
  (let* ((allisp::*run* (or run (make-test-run :responses responses)))
         (allisp::*current-file* nil)
         (env (allisp::make-global-env))
         (forms (allisp::read-allisp-string-all string))
         (value nil))
    (dolist (f forms)
      (setf value (allisp::eval-toplevel-form f env)))
    (values value allisp::*run*)))

(defun calls (run) (allisp::mock-calls (allisp::run-backend run)))
(defun rd (s) (allisp::read-allisp-string s))

(test reader-roundtrip
  (let ((form (rd "(observe foo :bar \"str\" 1.5 (a . b))")))
    (is (string= (allisp::print-sexp form :pretty nil)
                 "(observe foo :bar \"str\" 1.5 (a . b))"))))

(test reader-normalizes-t-nil
  (is (eq t (rd "t")))
  (is (eq nil (rd "nil")))
  (is (equal '(1) (multiple-value-bind (v) (ev "(if t '(1) '(2))") v))))

(test deterministic-arithmetic
  (multiple-value-bind (v run) (ev "(+ 1 (* 2 3))")
    (is (= v 7))
    (is (= 0 (calls run)))))

(test defun-and-closures
  (multiple-value-bind (v run) (ev "(defun sq (x) (* x x)) (sq 5)")
    (is (= v 25))
    (is (= 0 (calls run)))))

(test defmacro-quasiquote-splicing
  (multiple-value-bind (v run)
      (ev "(defmacro m (&rest xs) `(list ,@xs 9)) (m 1 2)")
    (is (equal v '(1 2 9)))
    (is (= 0 (calls run)))))

(test higher-order-builtins
  (multiple-value-bind (v) (ev "(mapcar (lambda (x) (* x 10)) '(1 2 3))")
    (is (equal v '(10 20 30))))
  (multiple-value-bind (v) (ev "(filter (lambda (x) (> x 1)) '(1 2 3))")
    (is (equal v '(2 3)))))

(test solve-deduces-all-solutions-with-constraints
  (multiple-value-bind (v run)
      (ev "
        (goal parent (alice bob))
        (goal parent (bob carol))
        (goal ancestor (?x ?y) (parent ?x ?y))
        (goal ancestor (?x ?y) (parent ?x ?z) (ancestor ?z ?y))
        (goal age (bob 20))
        (goal age (carol 12))
        (goal adult-descendant (?person)
          (ancestor alice ?person)
          (age ?person ?years)
          (constraint (>= ?years 18)))
        (solve (adult-descendant ?who))")
    (is (equal v (rd "((:who bob))")))
    (is (= 0 (calls run)))))

(test solve-supports-fact-head-form-and-direct-constraints
  (multiple-value-bind (v)
      (ev "(goal (score alice 9))
           (goal (score bob 4))
           (solve (score ?name ?score) (constraint (> ?score 5)))")
    (is (equal v (rd "((:name alice :score 9))")))))

(test get-property-builtin
  (is (= 7 (ev "(get-property '(foo :bar 7) 'bar)")))
  (is (eq (rd "high") (ev "(get-property '(x action-level high) 'action-level)")))
  (is (= 3 (ev "(get-property '(a b) 'zzz :default 3)"))))

(test unbound-goes-to-oracle
  (multiple-value-bind (v run)
      (ev "(mystery-analysis 1 2)" :responses '("(:answer 3)"))
    (is (equal v (rd "(:answer 3)")))
    (is (= 1 (calls run)))))

(test oracle-args-not-evaluated
  ;; normal-order: (- 40 :work-hours) inside an unbound form must not
  ;; reach the deterministic #'- as a keyword argument
  (multiple-value-bind (v run)
      (ev "(calculation (- 40 :work-hours))" :responses '("ok"))
    (is (eq v (rd "ok")))
    (is (= 1 (calls run)))))

(test defer-preserves-code-and-evaluates-its-metadata
  (multiple-value-bind (v run)
      (ev "(let ((reason \"waiting for approval\"))
             (defer (send-email customer) :reason reason))")
    (is (equal v
               (rd "(defer (send-email customer) :reason \"waiting for approval\")")))
    ;; Neither the deferred operator nor its arguments may reach the oracle.
    (is (= 0 (calls run)))))

(test deprecate-evaluates-code-and-retains-metadata
  (multiple-value-bind (v run)
      (ev "(let ((reason \"use new-total instead\"))
             (deprecate (+ 20 22) :reason reason))")
    (is (equal v
               (rd "(deprecate 42 :deprecated t :reason \"use new-total instead\")")))
    (is (= 0 (calls run)))))

(test host-syntax-macro-expands-before-evaluation
  (let ((name (allisp::usym "DUPLICATE-FOR-TEST")))
    (unwind-protect
         (progn
           (allisp:register-syntax-macro
            "duplicate-for-test"
            (lambda (form) `(list ,form ,form)))
           (multiple-value-bind (v run)
               (ev "(duplicate-for-test (+ 20 1))")
             (is (equal v '(21 21)))
             (is (= 0 (calls run)))))
      (remhash name allisp::*syntax-macros*))))

(test effect-position-escalates
  ;; (mystery x) sits in effect position; the whole LET must be oracled once
  (multiple-value-bind (v run)
      (ev "(let ((x 21)) (mystery x) (* x 2))" :responses '("99"))
    (is (= v 99))
    (is (= 1 (calls run)))
    (let ((prompt (first (allisp::mock-prompts (allisp::run-backend run)))))
      (is (search "(let ((x 21))" prompt)))))

(test oracle-cache-hit-across-runs
  (let ((root (fresh-root)))
    (multiple-value-bind (v1 run1)
        (ev "(mystery 1)" :run (make-test-run :responses '("7") :root root))
      (multiple-value-bind (v2 run2)
          (ev "(mystery 1)" :run (make-test-run :responses '("8") :root root))
        (is (= v1 7))
        (is (= v2 7)) ; from cache, not the new mock response
        (is (= 1 (calls run1)))
        (is (= 0 (calls run2)))))))

(test llm-forces-oracle
  (multiple-value-bind (v run) (ev "(llm (+ 1 2))" :responses '("3"))
    (is (= v 3))
    (is (= 1 (calls run)))))

(test pure-blocks-oracle
  (multiple-value-bind (v run) (ev "(pure (mystery 1))")
    (is (consp v))
    (is (string= "ERROR" (symbol-name (first v))))
    (is (= 0 (calls run)))
    (is (= 1 (length (allisp::run-errors run))))))

(test context-includes-definitions
  (multiple-value-bind (v run)
      (ev "(defmacro obs (name &rest data) \"Collect observations.\" `(record-obs ,name ,@data))
           (obs foo (x 1))"
          :responses '("(recorded foo)"))
    (declare (ignore v))
    (is (= 1 (calls run)))
    (let ((prompt (first (allisp::mock-prompts (allisp::run-backend run)))))
      (is (search "Collect observations." prompt))
      (is (search "(obs foo (x 1))" prompt)))))

(test claude-cli-args-agentic-allows-read-only-tools
  (let ((agentic (allisp::claude-cli-args
                  (make-instance 'allisp::claude-cli-backend) "sonnet"))
        (plain (allisp::claude-cli-args
                (make-instance 'allisp::claude-cli-backend :agentic nil)
                "sonnet")))
    (is (member "--allowedTools" agentic :test #'string=))
    (is (member "Read" agentic :test #'string=))
    (is (member "--strict-mcp-config" agentic :test #'string=))
    (is (not (member "--allowedTools" plain :test #'string=)))
    (is (equal '("claude" "-p" "--model" "sonnet") plain))))

(test agentic-prompt-includes-environment-and-anti-echo
  (let* ((root (fresh-root))
         (source (make-empty-file (merge-pathnames "think.lisp" root)))
         (run (make-test-run :root root :responses '("(:ok)"))))
    (let ((allisp::*run* run)
          (allisp::*current-file* source)
          (env (allisp::make-global-env)))
      (allisp::eval-toplevel-form (rd "(mystery 1)") env))
    (let ((prompt (first (allisp::mock-prompts (allisp::run-backend run)))))
      (is (search "=== Environment ===" prompt))
      (is (search (namestring source) prompt))
      (is (search (namestring root) prompt))
      (is (search "Read, Glob, and Grep" prompt))
      (is (search "never a restatement" prompt)))))

(test non-agentic-prompt-has-no-environment
  (let* ((root (fresh-root))
         (source (make-empty-file (merge-pathnames "think.lisp" root)))
         (run (allisp::make-run
               :root root :model "sonnet"
               :backend (make-instance 'allisp::mock-backend
                                       :responses '("(:ok)") :agentic nil))))
    (let ((allisp::*run* run)
          (allisp::*current-file* source)
          (env (allisp::make-global-env)))
      (allisp::eval-toplevel-form (rd "(mystery 1)") env))
    (let ((prompt (first (allisp::mock-prompts (allisp::run-backend run)))))
      (is (not (search "=== Environment ===" prompt)))
      ;; the anti-echo rule is unconditional
      (is (search "never a restatement" prompt)))))

(test one-liner-prompt-has-no-environment
  ;; no source file to explore from -> no exploration section
  (multiple-value-bind (v run) (ev "(mystery 1)" :responses '("(:ok)"))
    (declare (ignore v))
    (let ((prompt (first (allisp::mock-prompts (allisp::run-backend run)))))
      (is (not (search "=== Environment ===" prompt))))))

(test use-imports-definitions
  (let* ((root (fresh-root))
         (lib (merge-pathnames "lib.lisp" root)))
    (with-open-file (out lib :direction :output :if-exists :supersede)
      (write-string "(defun triple (x) (* x 3))" out))
    (let* ((allisp::*run* (make-test-run :root root))
           (allisp::*current-file* (merge-pathnames "main.lisp" root))
           (env (allisp::make-global-env)))
      (allisp::eval-toplevel-form (rd "(@use \"lib.lisp\")") env)
      (is (= 12 (allisp::eval-toplevel-form (rd "(triple 4)") env))))))

(test generate-file-writes-provenance-and-executable-code
  (let* ((root (fresh-root))
         (source (merge-pathnames "source.lisp" root))
         (target (merge-pathnames "generated/add-two.lisp" root))
         (source-form
           (rd "(generate-file \"generated/add-two.lisp\"
                  (synthesize-adder :increment 2))"))
         (run (make-test-run
               :root root
               :responses '("(defun add-two (x) (+ x 2))"))))
    (make-empty-file source)
    (let ((allisp::*run* run)
          (allisp::*current-file* source)
          (env (allisp::make-global-env)))
      (is (equal (rd "(defun add-two (x) (+ x 2))")
                 (allisp::eval-toplevel-form source-form env))))
    (is (= 1 (calls run)))
    (is (probe-file target))
    (let ((forms (allisp::read-allisp-file target)))
      (is (= 3 (length forms)))
      (is (eq (first (first forms)) (rd "defmacro")))
      (is (eq (first (second forms)) (rd "generated-by")))
      (is (equal (third forms) (rd "(defun add-two (x) (+ x 2))")))
      (let ((allisp::*run* (make-test-run :root root))
            (allisp::*current-file* target)
            (env (allisp::make-global-env))
            metadata)
        (allisp::eval-toplevel-form (first forms) env)
        (setf metadata (allisp::eval-toplevel-form (second forms) env))
        (allisp::eval-toplevel-form (third forms) env)
        (is (eq (getf metadata :generator) (rd "generate-file")))
        (is (string= (getf metadata :source) (namestring source)))
        (is (equal (getf metadata :form) source-form))
        (is (stringp (getf metadata :generated-at)))
        (multiple-value-bind (bound-metadata found)
            (allisp::env-lookup env (rd "*generated-by*"))
          (is (not (null found)))
          (is (equal bound-metadata metadata)))
        (is (= 42 (allisp::eval-toplevel-form (rd "(add-two 40)") env)))))))

(test generate-file-dry-run-does-not-write
  (let* ((root (fresh-root))
         (source (merge-pathnames "source.lisp" root))
         (target (merge-pathnames "generated.lisp" root))
         (run (make-test-run :root root)))
    (make-empty-file source)
    (setf (allisp::run-dry-run run) t)
    (let ((allisp::*run* run)
          (allisp::*current-file* source)
          (env (allisp::make-global-env)))
      (is (equal (rd "(+ 20 22)")
                 (allisp::eval-toplevel-form
                 (rd "(generate-file \"generated.lisp\" '(+ 20 22))") env))))
    (is (not (probe-file target)))))

(test generate-file-refuses-to-overwrite-source
  (let* ((root (fresh-root))
         (source (merge-pathnames "source.lisp" root))
         (run (make-test-run :root root)))
    (make-empty-file source)
    (let ((allisp::*run* run)
          (allisp::*current-file* source)
          (env (allisp::make-global-env)))
      (let ((value
              (allisp::eval-toplevel-form
               (rd "(generate-file \"source.lisp\" '(+ 20 22))") env)))
        (is (eq (first value) (rd "error")))
        (is (eq (getf (rest value) :type) :generated-path-is-source))))
    (is (string= "" (uiop:read-file-string source)))))

(test project-root-uses-nearest-marker
  (let* ((root (fresh-root))
         (source (merge-pathnames "src/nested/main.lisp" root)))
    (ensure-directories-exist (merge-pathnames ".git/placeholder" root))
    (make-empty-file source)
    (is (equal (truename root) (allisp::find-project-root source)))))

(test project-root-falls-back-to-source-directory
  (let* ((root (fresh-root))
         (source (merge-pathnames "standalone/main.lisp" root)))
    (make-empty-file source)
    (is (equal (uiop:pathname-directory-pathname (truename source))
               (allisp::find-project-root source)))))

(test one-liner-evaluates-all-forms-and-prints-last-value
  (let ((out (make-string-output-stream))
        (err (make-string-output-stream))
        (backend (make-instance 'allisp::mock-backend))
        code)
    (let ((*standard-output* out)
          (*error-output* err))
      (setf code
            (allisp:run-one-liner
             "(defun double (x) (* x 2)) (double 6)"
             :root (fresh-root) :backend backend)))
    (is (= 0 code))
    (is (string= "12
" (get-output-stream-string out)))
    (is (= 0 (allisp::mock-calls backend)))))

(test one-liner-supports-oracle-evaluation
  (let ((out (make-string-output-stream))
        (err (make-string-output-stream))
        (backend (make-instance 'allisp::mock-backend
                                :responses '("(:answer 3)")))
        code)
    (let ((*standard-output* out)
          (*error-output* err))
      (setf code
            (allisp:run-one-liner
             "(summarize 1 2)"
             :root (fresh-root) :backend backend)))
    (is (= 0 code))
    (is (string= "(:answer 3)
" (get-output-stream-string out)))
    (is (= 1 (allisp::mock-calls backend)))))

(test oracle-parse-retry-and-fences
  (multiple-value-bind (v run)
      (ev "(mystery 1)" :responses '("```lisp
(:ok 1)
```"))
    (is (equal v (rd "(:ok 1)")))
    (is (= 1 (calls run)))))

(test error-value-continues
  ;; three toplevel forms; middle one fails to parse 3 times -> error value,
  ;; but evaluation continues and errors are recorded
  (multiple-value-bind (v run)
      (ev "(defun f (x) x) (mystery 2) (f 10)"
          :responses '(") not lisp" ") still not" ") nope"))
    (is (= v 10))
    (is (= 1 (length (allisp::run-errors run))))
    (is (= 3 (calls run)))))

(test def-returns-bound-value
  ;; (def name expr) returns the bound value so result files record it and
  ;; (result ...) replay can restore the binding. defun keeps returning the
  ;; name: closures cannot be externalized, so there is nothing to replay.
  (multiple-value-bind (v run) (ev "(def x (+ 1 2))")
    (is (= v 3))
    (is (= 0 (calls run))))
  (is (equal (rd "(1 2)") (ev "(def x 1 2)")))
  (is (= 5 (ev "(define y 5)")))
  (is (eq (rd "f") (ev "(defun f (a) a)"))))

(test result-replay-restores-def-names
  (multiple-value-bind (v run)
      (ev "(result :v 2 :n 1 :form (def conclusion (plan_dsl)) :value (a b c))
           (pure (list conclusion last-result))")
    (is (equal (rd "((a b c) (a b c))") v))
    (is (= 0 (calls run)))))

(test result-replay-v1-does-not-restore
  ;; v1 files recorded the defined name as :value; restoring would silently
  ;; bind conclusion to the symbol conclusion, so replay must skip it.
  (multiple-value-bind (v run)
      (ev "(result :n 1 :form (def conclusion (plan_dsl)) :value conclusion)
           (pure conclusion)")
    (is (consp v))
    (is (eq (rd "error") (first v)))
    (is (= 0 (calls run)))))

(test result-replay-skips-host-placeholders
  (multiple-value-bind (v run)
      (ev "(result :v 2 :n 1 :form (def g (lambda (x) x)) :value (closure anonymous))
           (pure g)")
    (is (consp v))
    (is (eq (rd "error") (first v)))
    (is (= 0 (calls run)))))

(test result-file-chains-def-values
  ;; End to end: run a file that defs a value, @use its result file from a
  ;; fresh environment, and read the value back by name with no oracle calls.
  (let* ((root (fresh-root))
         (src (merge-pathnames "up.lisp" root)))
    (with-open-file (out src :direction :output :if-exists :supersede)
      (write-string "(def conclusion '(gap work money)) (+ 1 2)" out))
    (is (= 0 (allisp::run-file
              src :backend (make-instance 'allisp::mock-backend :responses '()))))
    (multiple-value-bind (v run)
        (ev (format nil "(@use \"~a\") (pure (list conclusion last-result))"
                    (namestring (merge-pathnames "output/up.result.lisp" root)))
            :run (make-test-run :root root))
      (is (equal (rd "((gap work money) 3)") v))
      (is (= 0 (calls run))))))

(test run-file-out-dir-redirects-outputs
  (let* ((root (fresh-root))
         (src (merge-pathnames "up.lisp" root))
         (out-dir (merge-pathnames "elsewhere/" root)))
    (with-open-file (out src :direction :output :if-exists :supersede)
      (write-string "(+ 1 2)" out))
    (is (= 0 (allisp::run-file
              src :backend (make-instance 'allisp::mock-backend :responses '())
                  :out-dir (namestring out-dir))))
    (is (probe-file (merge-pathnames "up.result.lisp" out-dir)))
    (is (probe-file (merge-pathnames "up.trace.lisp" out-dir)))
    (is (not (probe-file (merge-pathnames "output/up.result.lisp" root))))))

(test generate-file-writes-raw-text-for-non-lisp-target
  (let* ((root (fresh-root))
         (source (make-empty-file (merge-pathnames "gen.lisp" root)))
         (target (merge-pathnames "out/run.py" root))
         (run (make-test-run :root root)))
    (let ((allisp::*run* run)
          (allisp::*current-file* source)
          (env (allisp::make-global-env)))
      (is (string= "print(40 + 2)"
                   (allisp::eval-toplevel-form
                    (rd "(generate-file \"out/run.py\" \"print(40 + 2)\")") env))))
    (is (probe-file target))
    (is (string= (format nil "print(40 + 2)~%")
                 (uiop:read-file-string target)))))

(test generate-file-rejects-non-string-for-non-lisp-target
  (let* ((root (fresh-root))
         (source (make-empty-file (merge-pathnames "gen.lisp" root)))
         (run (make-test-run :root root)))
    (let ((allisp::*run* run)
          (allisp::*current-file* source)
          (env (allisp::make-global-env)))
      (let ((value (allisp::eval-toplevel-form
                    (rd "(generate-file \"out/run.py\" '(+ 20 22))") env)))
        (is (eq (rd "error") (first value)))
        (is (eq (getf (rest value) :type) :generated-text-not-string))))
    (is (not (probe-file (merge-pathnames "out/run.py" root))))))

(test generate-file-hints-oracle-to-return-string-for-non-lisp-target
  (let* ((root (fresh-root))
         (source (make-empty-file (merge-pathnames "gen.lisp" root)))
         (run (make-test-run :root root :responses '("\"print(1)\""))))
    (let ((allisp::*run* run)
          (allisp::*current-file* source)
          (env (allisp::make-global-env)))
      (allisp::eval-toplevel-form
       (rd "(generate-file \"out/run.py\" (synthesize-script))") env))
    (is (= 1 (calls run)))
    (let ((prompt (first (allisp::mock-prompts (allisp::run-backend run)))))
      (is (search "double-quoted Lisp string" prompt)))
    (is (string= (format nil "print(1)~%")
                 (uiop:read-file-string (merge-pathnames "out/run.py" root))))))

(test lisp-target-prompt-has-no-string-hint
  (let* ((root (fresh-root))
         (source (make-empty-file (merge-pathnames "gen.lisp" root)))
         (run (make-test-run :root root :responses '("(defun f (x) x)"))))
    (let ((allisp::*run* run)
          (allisp::*current-file* source)
          (env (allisp::make-global-env)))
      (allisp::eval-toplevel-form
       (rd "(generate-file \"out/lib.lisp\" (synthesize-lib))") env))
    (let ((prompt (first (allisp::mock-prompts (allisp::run-backend run)))))
      (is (not (search "double-quoted Lisp string" prompt))))))

(test oracle-string-response-with-parens-parses-whole
  ;; A string-literal response containing parens must not be truncated by the
  ;; skip-leading-prose heuristic.
  (multiple-value-bind (v run)
      (ev "(mystery 1)" :responses '("\"print(40 + 2)\""))
    (is (string= "print(40 + 2)" v))
    (is (= 1 (calls run)))))

(test oracle-string-response-unescapes-c-style
  (multiple-value-bind (v run)
      (ev "(mystery 1)" :responses '("\"line1\\nline2 \\\"quoted\\\" tab\\there\""))
    (declare (ignore run))
    (is (string= (format nil "line1~%line2 \"quoted\" tab~ahere" #\Tab) v))))

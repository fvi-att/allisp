(in-package #:allisp)

;;; The meta-circular evaluator.
;;;
;;; Two rules distinguish allisp from an ordinary Lisp:
;;;
;;; 1. Normal-order oracle fallback — a form whose operator is unbound is NOT
;;;    an error and its arguments are NOT evaluated; the whole form plus its
;;;    referenced definitions/bindings goes to the LLM oracle.  The oracle
;;;    generates Lisp code; allisp executes it only after every operator and
;;;    referenced value can be resolved by the deterministic evaluator.
;;;
;;; 2. Effect-position escalation — an oracle cannot perform side effects, so
;;;    when an unbound form sits in effect position (its value would be
;;;    discarded, e.g. a non-final body form), evaluation escalates: the
;;;    nearest enclosing value-position form is sent to the oracle whole.

(define-condition escalate-request (condition)
  ((form :initarg :form :reader escalate-form)))

(defparameter +missing+ '#:missing
  "Sentinel distinguishing an absent keyword argument from an explicit NIL.")

(defvar *oracle-string-hint* nil
  "When true, oracle prompts ask for the value as one Lisp string literal.
Bound by generate-file around the body evaluation for non-.lisp targets,
where the value is written verbatim into a script or document. The extra
rule changes the prompt, so these calls get their own cache entries.")

(defvar *oracle-fix-hint* nil
  "When true, the oracle prompt gains a Fix-mode section: the target form is
inert intermediate code, and the oracle is authorized to resolve it by
choosing reasonable defaults, binding every assumption explicitly in the
generated code. Bound by FIX. The extra section changes the prompt, so fix
passes get their own cache entries.")

(defvar *oracle-markdown-hint* nil
  "When bound to (:label L :text T), the oracle prompt gains a markdown
conversion section: the document T is to be converted into allisp forms with
prose forbidden. Bound by MARKDOWN->LISP. The document is part of the prompt,
so each document revision gets its own cache entry.")

;; ---------------------------------------------------------------- entry

(defun a-eval (form env &optional effect)
  (if effect
      (%eval form env t)
      (handler-case (%eval form env nil)
        (escalate-request (c)
          (declare (ignore c))
          (oracle-eval form env)))))

(defun %eval (form env effect)
  (cond
    ((null form) nil)
    ((eq form t) t)
    ((keywordp form) form)
    ((symbolp form)
     (multiple-value-bind (v found) (env-lookup env form)
       (if found v (unbound form env effect))))
    ((atom form) form)
    ((not (proper-list-p form)) (unbound form env effect))
    (t
     (let ((op (car form)))
       (if (and (symbolp op) (special-form-p op))
           (eval-special op form env effect)
           (multiple-value-bind (fn found)
               (if (symbolp op)
                   (env-lookup env op)
                   (values (a-eval op env) t))
             (cond
               ((not found) (unbound form env effect))
               ((syntax-macro-p fn) (expand-syntax-and-eval fn form env effect))
               ((macro-obj-p fn) (expand-and-eval fn form env effect))
               (t (a-apply fn (mapcar (lambda (a) (a-eval a env)) (cdr form)))))))))))

(defun unbound (form env effect)
  "An unbound symbol or unbound-operator form. Oracle, escalate, or error."
  (cond
    (*pure*
     (make-error-value :unbound-in-pure form
                       "unbound inside (pure ...); no oracle fallback"))
    (effect
     (signal 'escalate-request :form form)
     ;; No handler above (cannot happen from run-file, whose toplevel is
     ;; value position) — degrade to a direct oracle call.
     (oracle-eval form env))
    (t (oracle-eval form env))))

(defun proper-list-p (x)
  (loop for tail = x then (cdr tail)
        do (cond ((null tail) (return t))
                 ((not (consp tail)) (return nil)))))

;; ---------------------------------------------------------------- application

(defun fnify (f)
  "Adapt an allisp value to a CL function, for passing into CL builtins."
  (etypecase f
    (function f)
    (closure (lambda (&rest args) (a-apply f args)))))

(defun a-apply (fn args)
  (typecase fn
    (function (apply fn (mapcar (lambda (a) (if (closure-p a) (fnify a) a)) args)))
    (closure
     (let ((env (make-env (closure-env fn))))
       (bind-lambda-list (closure-params fn) args env)
       (eval-body (closure-body fn) env nil)))
    (t (make-error-value :not-a-function fn
                         (format nil "~a applied to ~a arguments"
                                 (form-summary fn) (length args))))))

(defun eval-body (forms env final-effect)
  "Evaluate FORMS in sequence. Non-final forms are effect position; the final
form inherits FINAL-EFFECT. Returns the final value."
  (if (null forms)
      nil
      (loop for rest on forms
            if (cdr rest)
              do (let ((f (car rest)))
                   ;; Constants in effect position are inert docstrings/tags.
                   (unless (or (stringp f) (keywordp f) (numberp f))
                     (a-eval f env t)))
            else
              return (a-eval (car rest) env final-effect))))

;; ---------------------------------------------------------------- lambda lists

(defun lambda-list-marker-p (sym name)
  (and (symbolp sym) sym (string= (symbol-name sym) name)))

(defun bind-lambda-list (params args env)
  "Bind PARAMS (required, &optional, &rest/&body, &key) to ARGS in ENV.
Lenient in the CL spirit but never signals on odd keyword tails: thought DSLs
mix keywords and forms freely; unmatched keys default instead of erroring."
  ;; Scheme-style dotted tail: (a b . rest)
  (let ((params (loop for tail = params then (cdr tail)
                      until (or (null tail) (not (consp tail)))
                      collect (car tail) into flat
                      finally (return (if (null tail)
                                          flat
                                          (append flat (list (usym "&REST") tail)))))))
    (let ((mode :required))
      (dolist (p params)
        (cond
          ((lambda-list-marker-p p "&OPTIONAL") (setf mode :optional))
          ((or (lambda-list-marker-p p "&REST")
               (lambda-list-marker-p p "&BODY")) (setf mode :rest))
          ((lambda-list-marker-p p "&KEY") (setf mode :key))
          (t
           (ecase mode
             (:required
              (unless args (error "allisp: too few arguments (wanted ~a)" p))
              (env-define env p (pop args)))
             (:optional
              (let ((var (if (consp p) (first p) p))
                    (default (if (consp p) (second p) nil)))
                (env-define env var
                            (if args (pop args)
                                (and default (a-eval default env))))))
             (:rest
              (env-define env p args)
              (setf args nil))
             (:key
              (let* ((var (if (consp p) (first p) p))
                     (default (if (consp p) (second p) nil))
                     (kw (intern (symbol-name var) :keyword))
                     (found (safe-getf args kw)))
                (env-define env var
                            (if (eq found +missing+)
                                (and default (a-eval default env))
                                found)))))))))))

(defun safe-getf (list key)
  "GETF that tolerates non-plist junk (odd tails, dotted lists).
Returns the value or +MISSING+."
  (loop for tail = list then (cddr tail)
        while (and (consp tail) (consp (cdr tail)))
        when (eq (car tail) key)
          return (cadr tail)
        finally (return +missing+)))

;; ---------------------------------------------------------------- macros

(defun expand-and-eval (macro form env effect)
  (let ((menv (make-env (macro-obj-env macro))))
    (bind-lambda-list (macro-obj-params macro) (cdr form) menv)
    (let ((expansion (eval-body (macro-obj-body macro) menv nil)))
      (if effect
          (%eval expansion env t)
          (handler-case (%eval expansion env nil)
            (escalate-request (c)
              (declare (ignore c))
              ;; Escalation inside the expansion lands on the original call —
              ;; the readable, cache-stable unit the author actually wrote.
              (oracle-eval form env)))))))

(defun expand-syntax-and-eval (macro form env effect)
  "Expand a host-provided syntax macro over raw allisp arguments."
  (let ((expansion (normalize (apply (syntax-macro-expander macro) (cdr form)))))
    (if effect
        (%eval expansion env t)
        (handler-case (%eval expansion env nil)
          (escalate-request (c)
            (declare (ignore c))
            (oracle-eval form env))))))

;; ---------------------------------------------------------------- quasiquote

(defun eval-qq (x depth env)
  (cond
    ((not (consp x)) x)
    ((eq (car x) +unquote+)
     (if (= depth 1)
         (a-eval (cadr x) env)
         (list +unquote+ (eval-qq (cadr x) (1- depth) env))))
    ((eq (car x) +quasiquote+)
     (list +quasiquote+ (eval-qq (cadr x) (1+ depth) env)))
    (t (qq-list x depth env))))

(defun qq-list (x depth env)
  (cond
    ((null x) nil)
    ((not (consp x)) x)
    ;; dotted tail unquote: `(a . ,b)
    ((eq (car x) +unquote+)
     (if (= depth 1)
         (a-eval (cadr x) env)
         (list +unquote+ (eval-qq (cadr x) (1- depth) env))))
    ((and (consp (car x)) (eq (caar x) +unquote-splicing+) (= depth 1))
     (append (a-eval (cadr (car x)) env)
             (qq-list (cdr x) depth env)))
    (t (cons (eval-qq (car x) depth env)
             (qq-list (cdr x) depth env)))))

;; ---------------------------------------------------------------- special forms

(defparameter +special-form-names+
  '("QUOTE" "QUASIQUOTE" "IF" "COND" "WHEN" "UNLESS"
    "LET" "LET*" "LAMBDA" "PROGN" "AND" "OR"
    "DEFUN" "DEFINE" "DEFMACRO" "DEF" "DEFVAR" "DEFPARAMETER"
    "SETQ" "SETF" "PUSH" "INCF" "DECF"
    "@USE" "LLM" "PURE" "FIX" "DEFER" "DEPRECATE" "RESULT" "INTERMEDIATE-CODE"
    "MARKDOWN->LISP"
    "%GENERATE-FILE" "%GOAL" "%SOLVE" "%CONSTRAINT"))

(defparameter +special-forms+
  (let ((h (make-hash-table :test #'eq)))
    (dolist (n +special-form-names+ h)
      (setf (gethash (usym n) h) t))))

(defun special-form-p (sym)
  (gethash sym +special-forms+))

(defun eval-special (op form env effect)
  (let ((name (symbol-name op))
        (rest (cdr form)))
    (macrolet ((is (n) `(string= name ,n)))
      (cond
        ((is "QUOTE") (first rest))
        ((is "QUASIQUOTE") (eval-qq (first rest) 1 env))
        ((is "IF")
         (if (a-eval (first rest) env)
             (a-eval (second rest) env effect)
             (when (cddr rest) (a-eval (third rest) env effect))))
        ((is "COND")
         (loop for clause in rest
               do (let ((test (first clause)))
                    (when (or (eq test t)
                              (lambda-list-marker-p test "ELSE")
                              (a-eval test env))
                      (return (if (cdr clause)
                                  (eval-body (cdr clause) env effect)
                                  t))))
               finally (return nil)))
        ((is "WHEN")
         (when (a-eval (first rest) env)
           (eval-body (cdr rest) env effect)))
        ((is "UNLESS")
         (unless (a-eval (first rest) env)
           (eval-body (cdr rest) env effect)))
        ((is "LET") (eval-let rest env effect nil))
        ((is "LET*") (eval-let rest env effect t))
        ((is "LAMBDA")
         (make-closure :params (first rest) :body (cdr rest)
                       :env env :source form))
        ((is "PROGN") (eval-body rest env effect))
        ((is "AND")
         (loop with v = t
               for f in rest
               do (setf v (a-eval f env))
               while v
               finally (return v)))
        ((is "OR")
         (loop for f in rest
               for v = (a-eval f env)
               when v return v))
        ((is "DEFUN")
         (destructuring-bind (fname params &rest body) rest
           (env-define env fname
                       (make-closure :name fname :params params :body body
                                     :env env :source form))
           fname))
        ((is "DEFINE")
         (if (consp (first rest))
             ;; (define (name . params) body...)
             (let ((fname (car (first rest)))
                   (params (cdr (first rest))))
               (env-define env fname
                           (make-closure :name fname :params params
                                         :body (cdr rest) :env env :source form))
               fname)
             (let ((val (when (cdr rest) (a-eval (second rest) env))))
               (env-define env (first rest) val)
               val)))
        ((is "DEFMACRO")
         (destructuring-bind (mname params &rest body) rest
           (env-define env mname
                       (make-macro-obj :name mname :params params :body body
                                       :env env :source form))
           mname))
        ((or (is "DEF") (is "DEFVAR") (is "DEFPARAMETER"))
         ;; (def name expr) evaluates; (def name f1 f2 ...) stores the forms
         ;; as data so prose-like constant tables do not become programs.
         ;; Returns the bound value (not the name) so result files record it
         ;; and (result ...) replay can restore the binding by name.
         (let ((var (first rest))
               (val (cond ((null (cdr rest)) nil)
                          ((null (cddr rest)) (a-eval (second rest) env))
                          (t (cdr rest)))))
           (env-define env var val)
           val))
        ((is "SETQ")
         (loop for (var val) on rest by #'cddr
               for v = (a-eval val env)
               do (env-set env var v)
               finally (return v)))
        ((is "SETF")
         (if (and (= (length rest) 2) (symbolp (first rest)))
             (let ((v (a-eval (second rest) env)))
               (env-set env (first rest) v)
               v)
             ;; Non-variable places are beyond the deterministic core.
             (unbound form env effect)))
        ((is "PUSH")
         (destructuring-bind (val var) rest
           (if (symbolp var)
               (let ((v (cons (a-eval val env)
                              (multiple-value-bind (cur found) (env-lookup env var)
                                (and found cur)))))
                 (env-set env var v)
                 v)
               (unbound form env effect))))
        ((or (is "INCF") (is "DECF"))
         (destructuring-bind (var &optional (delta 1)) rest
           (multiple-value-bind (cur found) (env-lookup env var)
             (if (and found (numberp cur) (symbolp var))
                 (let ((v (funcall (if (is "INCF") #'+ #'-)
                                   cur (a-eval delta env))))
                   (env-set env var v)
                   v)
                 (unbound form env effect)))))
        ((is "@USE") (eval-use form env))
        ((is "RESULT") (eval-result form env))
        ;; An unresolved oracle program is inert data. Normalize its reason so
        ;; every stage records both why it stopped and how to continue.
        ((is "INTERMEDIATE-CODE") (normalize-intermediate-code form))
        ((is "LLM") (eval-llm form env))
        ((is "FIX") (eval-fix form env))
        ((is "MARKDOWN->LISP") (eval-markdown->lisp form env))
        ((is "DEFER")
         ;; Preserve the decision's code verbatim.  The remaining arguments
         ;; are metadata and are evaluated so a reason can refer to bindings.
         (cons op (cons (first rest) (eval-metadata (cdr rest) env))))
        ((is "DEPRECATE")
         ;; Unlike DEFER, deprecated code still runs.  Keep the evaluated
         ;; result in a tagged S-expression so the deprecation decision and
         ;; its metadata survive in result files and later compositions.
         (list* op (a-eval (first rest) env effect)
                :deprecated t
                (eval-metadata (cdr rest) env)))
        ((is "%GENERATE-FILE") (eval-generate-file form env))
        ((is "%GOAL") (eval-goal form env))
        ((is "%SOLVE") (eval-solve form env))
        ((is "%CONSTRAINT") (eval-constraint form env))
        ((is "PURE")
         (let ((*pure* t))
           (eval-body rest env effect)))
        (t (unbound form env effect))))))

(defun eval-metadata (metadata env)
  "Evaluate metadata values while retaining their plist layout.
Keywords are self-evaluating, so `(defer code :reason reason)` retains the
`:reason` key and resolves REASON without ever evaluating CODE."
  (mapcar (lambda (item) (a-eval item env)) metadata))

(defun eval-let (rest env effect sequential)
  (destructuring-bind (bindings &rest body) rest
    (let ((new (make-env env)))
      (dolist (b bindings)
        (let* ((var (if (consp b) (first b) b))
               (init (if (consp b) (second b) nil))
               (val (and init (a-eval init (if sequential new env)))))
          (env-define new var val)))
      (eval-body body new effect))))

;; ---------------------------------------------------------------- logic programming

;; A logic variable is an allisp symbol whose name starts with ?.  Variables
;; are data in goals, never evaluator bindings, so rules can be written in the
;; compact Prolog-like style `(goal (ancestor ?x ?y) ...)`.
(defparameter +logic-failure+ (gensym "LOGIC-FAILURE"))

(defun logic-variable-p (x)
  (and (symbolp x)
       (> (length (symbol-name x)) 0)
       (char= (char (symbol-name x) 0) #\?)))

(defun logic-root-env (env)
  (loop for current = env then (env-parent current)
        while (env-parent current)
        finally (return current)))

(defun logic-deref (term bindings)
  (loop while (logic-variable-p term)
        for entry = (assoc term bindings :test #'eq)
        while entry
        do (setf term (cdr entry))
        finally (return term)))

(defun logic-reify (term bindings)
  (let ((value (logic-deref term bindings)))
    (if (consp value)
        (cons (logic-reify (car value) bindings)
              (logic-reify (cdr value) bindings))
        value)))

(defun logic-unify (left right bindings)
  "Return extended BINDINGS, or +LOGIC-FAILURE+, when terms do not unify."
  (let ((left (logic-deref left bindings))
        (right (logic-deref right bindings)))
    (cond ((eql left right) bindings)
          ((logic-variable-p left) (acons left right bindings))
          ((logic-variable-p right) (acons right left bindings))
          ((and (consp left) (consp right))
           (let ((next (logic-unify (car left) (car right) bindings)))
             (if (eq next +logic-failure+)
                 +logic-failure+
                 (logic-unify (cdr left) (cdr right) next))))
          (t +logic-failure+))))

(defun logic-freshen (form)
  "Standardize a rule apart before each use, preventing variable capture."
  (let ((renames (make-hash-table :test #'eq)))
    (labels ((walk (x)
               (cond ((logic-variable-p x)
                      (or (gethash x renames)
                          (setf (gethash x renames)
                                (make-symbol (format nil "~a/~a" x (gensym))))))
                     ((consp x) (cons (walk (car x)) (walk (cdr x))))
                     (t x))))
      (walk form))))

(defun logic-vars (form)
  (let (vars)
    (labels ((walk (x)
               (cond ((logic-variable-p x) (pushnew x vars :test #'eq))
                     ((consp x) (walk (car x)) (walk (cdr x))))))
      (walk form)
      (nreverse vars))))

(defun logic-constraint-p (clause)
  (and (consp clause) (symbolp (car clause))
       (string= (symbol-name (car clause)) "CONSTRAINT")
       (= (length clause) 2)))

(defun logic-constraint-value (form bindings env)
  (let ((*pure* t))
    (a-eval (logic-reify form bindings) env)))

(defun logic-error-value-p (value)
  (and (consp value) (eq (car value) (usym "ERROR"))))

(defun logic-check-constraints (pending bindings env &optional final)
  "Evaluate constraints whose variables are bound.  Unready constraints are
kept until a later goal supplies their variables; at a completed proof they
make the branch fail."
  (let (remaining)
    (dolist (constraint pending)
      (if (and (not final)
               (some (lambda (v) (eq (logic-deref v bindings) v))
                     (logic-vars constraint)))
          (push constraint remaining)
          (let ((value (logic-constraint-value constraint bindings env)))
            (unless (and value (not (logic-error-value-p value)))
              (return-from logic-check-constraints (values nil nil))))))
    (values t (nreverse remaining))))

(defun logic-search (clauses rules env bindings pending)
  (if (null clauses)
      (multiple-value-bind (ok ignored)
          (logic-check-constraints pending bindings env t)
        (declare (ignore ignored))
        (and ok (list bindings)))
      (let ((clause (car clauses))
            (rest (cdr clauses)))
        (if (logic-constraint-p clause)
            (multiple-value-bind (ok next-pending)
                (logic-check-constraints (append pending (list (second clause)))
                                         bindings env)
              (and ok (logic-search rest rules env bindings next-pending)))
            (loop for rule in rules append
                  (let* ((fresh (logic-freshen rule))
                         (head (car fresh))
                         (body (cdr fresh))
                         (next (logic-unify clause head bindings)))
                    (if (not (eq next +logic-failure+))
                        (multiple-value-bind (ok next-pending)
                            (logic-check-constraints pending next env)
                          (if ok
                              (logic-search (append body rest) rules env next next-pending)
                              nil))
                        nil)))))))

(defun logic-answer (variables bindings)
  (loop for variable in variables
        for name = (symbol-name variable)
        for key = (intern (subseq name 1) :keyword)
        append (list key (logic-reify variable bindings))))

(defun eval-goal (form env)
  (destructuring-bind (operator head-form body-form) form
    (declare (ignore operator))
    (let* ((head-form (a-eval head-form env))
           (body (a-eval body-form env))
           ;; Both (goal (parent alice bob)) and the convenient
           ;; (goal parent (alice bob)) notation define a fact.
           (head (if (symbolp head-form)
                     (cons head-form (or (first body) nil))
                     head-form))
           (rule-body (if (symbolp head-form) (rest body) body)))
      (if (and (consp head) (symbolp (car head)))
          (let ((root (logic-root-env env)))
            (setf (env-logic-rules root)
                  (append (env-logic-rules root) (list (cons head rule-body))))
            (car head))
          (make-error-value :invalid-goal form
                            "goal head must be a predicate form")))))

(defun eval-solve (form env)
  (destructuring-bind (operator clauses) form
    (declare (ignore operator))
    (let* ((clauses (a-eval clauses env))
           (rules (env-logic-rules (logic-root-env env)))
           (variables (logic-vars clauses))
           (solutions (logic-search clauses rules env nil nil)))
      (mapcar (lambda (bindings) (logic-answer variables bindings)) solutions))))

(defun eval-constraint (form env)
  (destructuring-bind (operator constraint) form
    (declare (ignore operator))
    ;; Outside solve, constraint remains useful as a deterministic guard.
    (logic-constraint-value (a-eval constraint env) nil env)))

;; ---------------------------------------------------------------- generate-file

(defparameter +generate-file-macro-source+
  "(defmacro generate-file (path &body body)
  `(%generate-file ,path
     (progn ,@body)
     (quote (generate-file ,path ,@body))))")

(defparameter +goal-macro-source+
  "(defmacro goal (head &body body)
  `(%goal (quote ,head) (quote ,body)))")

(defparameter +constraint-macro-source+
  "(defmacro constraint (form)
  `(%constraint (quote ,form)))")

(defparameter +solve-macro-source+
  "(defmacro solve (&body clauses)
  `(%solve (quote ,clauses)))")

(defparameter +generated-by-macro-source+
  "(defmacro generated-by (generator &key source form generated-at)
  `(progn
     (def *generated-by*
       (quote (:generator ,generator
               :source ,source
               :form ,form
               :generated-at ,generated-at)))
     *generated-by*))")

(defun install-core-macros (env)
  (dolist (source (list +generate-file-macro-source+
                        +goal-macro-source+
                        +constraint-macro-source+
                        +solve-macro-source+) env)
    (let ((form (read-allisp-string source)))
      (destructuring-bind (operator name params &rest body) form
        (declare (ignore operator))
        (env-define env name
                    (make-macro-obj :name name :params params :body body
                                    :env env :source form))))))

(defun generated-path (path)
  (let ((base (if *current-file*
                  (uiop:pathname-directory-pathname *current-file*)
                  (uiop:getcwd))))
    (uiop:ensure-absolute-pathname path base)))

(defun source-and-target-equal-p (target)
  (and *current-file*
       (or (equal (namestring (uiop:ensure-absolute-pathname *current-file*))
                  (namestring target))
           (and (uiop:file-exists-p target)
                (equal (truename *current-file*) (truename target))))))

(defun generated-by-marker (source form generated-at
                            &optional (generator (usym "GENERATE-FILE")))
  (list (usym "GENERATED-BY") generator
        :source source :form form :generated-at generated-at))

(defun write-generated-source (target value origin-form)
  (let* ((generated-at (timestamp-string))
         (source (if *current-file* (namestring *current-file*) "<one-liner>"))
         (marker (generated-by-marker source origin-form generated-at)))
    (ensure-directories-exist target)
    (with-open-file (out target :direction :output :if-exists :supersede
                                :external-format :utf-8)
      (format out ";; Generated by allisp generate-file. Do not edit manually.~%")
      (format out ";; generated: ~a~%~%" generated-at)
      (write-string +generated-by-macro-source+ out)
      (format out "~%~%~a~%~%~a~%"
              (print-sexp marker)
              (print-sexp (externalize value))))
    target))

(defun write-generated-text (target text)
  "Write TEXT verbatim (plus a final newline when missing) for non-.lisp
targets such as scripts. No header is embedded: comment syntax varies by
format (JSON has none), so provenance lives in the trace instead."
  (ensure-directories-exist target)
  (with-open-file (out target :direction :output :if-exists :supersede
                              :external-format :utf-8)
    (write-string text out)
    (let ((len (length text)))
      (unless (and (plusp len) (char= (char text (1- len)) #\Newline))
        (terpri out))))
  target)

(defun eval-generate-file (form env)
  (destructuring-bind (operator path-form value-form &optional origin-form) form
    (declare (ignore operator))
    (let ((path (a-eval path-form env)))
      (unless (stringp path)
        (return-from eval-generate-file
          (make-error-value :invalid-generated-path form
                            "generate-file path must evaluate to a string")))
      (let* ((lisp-target (string-equal (pathname-type path) "lisp"))
             ;; Non-.lisp targets need a raw string; steer oracle calls made
             ;; while evaluating the body toward returning one.
             (value (let ((*oracle-string-hint* (not lisp-target)))
                      (a-eval value-form env))))
        (when (and (consp value) (eq (first value) (usym "ERROR")))
          (return-from eval-generate-file value))
        (let ((target (generated-path path))
              (origin (if origin-form (a-eval origin-form env) *current-toplevel*)))
          (when (source-and-target-equal-p target)
            (return-from eval-generate-file
              (make-error-value :generated-path-is-source form
                                "generate-file cannot overwrite its source file")))
          (progn
            (if (and *run* (run-dry-run *run*))
                (format *error-output* "~&[allisp]   would generate ~a~%"
                        (namestring target))
                (progn
                  ;; Non-.lisp targets (scripts, JSON, ...) take a raw string;
                  ;; refuse anything else so an S-expression never lands in a
                  ;; file another tool will execute or parse.
                  (unless (or lisp-target (stringp value))
                    (return-from eval-generate-file
                      (make-error-value :generated-text-not-string form
                                        "non-.lisp target requires a string value")))
                  (handler-case
                      (progn
                        (if lisp-target
                            (write-generated-source target value origin)
                            (write-generated-text target value))
                        (format *error-output* "~&[allisp]   generated ~a~%"
                                (namestring target)))
                    (error (e)
                      (return-from eval-generate-file
                        (make-error-value :generate-file-error form
                                          (princ-to-string e)))))))
            value))))))

;; ---------------------------------------------------------------- @use

(defun eval-use (form env)
  (let* ((rel (second form))
         (base (if *current-file*
                   (uiop:pathname-directory-pathname *current-file*)
                   (uiop:getcwd)))
         (path (uiop:merge-pathnames* rel base))
         (true (handler-case (namestring (truename path))
                 (error ()
                   (return-from eval-use
                     (make-error-value :use-not-found form
                                       (format nil "no such file: ~a" path)))))))
    (unless (and *run* (gethash true (run-loaded *run*)))
      (when *run* (setf (gethash true (run-loaded *run*)) t))
      (let ((*current-file* (pathname true)))
        (dolist (f (read-allisp-file true))
          (eval-toplevel-form f env))))
    t))

;; ---------------------------------------------------------------- result replay

(defparameter +result-format-version+ 2)

(defun def-form-name (form)
  "Return the defined name when FORM is a data-definition form whose value a
result file can restore: def / defvar / defparameter, or the variable form of
define. Function definitions (defun, defmacro, define with a lambda list) are
excluded because closures do not survive externalization."
  (when (and (consp form) (symbolp (first form)) (symbolp (second form)))
    (let ((head (symbol-name (first form))))
      (when (or (string= head "DEF") (string= head "DEFVAR")
                (string= head "DEFPARAMETER") (string= head "DEFINE"))
        (second form)))))

(defun restorable-value-p (value)
  "Host objects are written to result files as placeholders such as
(closure name); those must not be rebound as if they were data."
  (not (and (consp value)
            (symbolp (first value))
            (member (symbol-name (first value))
                    '("CLOSURE" "MACRO" "BUILTIN" "HASH-TABLE")
                    :test #'string=))))

(defun eval-result (form env)
  "Replay a (result :v 2 :n K :form F :value V) record from a .result.lisp
file. F is never re-evaluated and V is treated as data, so replay performs no
oracle calls. From format version 2 on, a def-family F re-establishes its
name -> V binding; last-result always tracks the latest V. Version 1 files
recorded the defined name as V, so their defs are not restored."
  (let* ((plist (cdr form))
         (version (let ((v (safe-getf plist :v)))
                    (if (eq v +missing+) 1 v)))
         (source (let ((f (safe-getf plist :form)))
                   (unless (eq f +missing+) f)))
         (value (let ((v (safe-getf plist :value)))
                  (unless (eq v +missing+) v))))
    (when (and (integerp version) (>= version 2))
      (let ((name (def-form-name source)))
        (when (and name (restorable-value-p value))
          (env-define env name value))))
    (env-define env (usym "LAST-RESULT") value)
    value))

(defun eval-toplevel-form (form env)
  (let ((*current-toplevel* form))
    (handler-case (a-eval form env)
      (error (e)
        (if (and *run* (run-strict *run*))
            (error e)
            (make-error-value :host-error form (princ-to-string e)))))))

;; ---------------------------------------------------------------- (llm ...)

(defun model-string (m)
  (string-downcase (string m)))

(defun eval-llm (form env)
  (destructuring-bind (subform &rest opts) (cdr form)
    (oracle-eval subform env
                 :model (let ((m (safe-getf opts :model)))
                          (unless (eq m +missing+) (model-string m)))
                 :fresh (let ((f (safe-getf opts :fresh)))
                          (and (not (eq f +missing+)) f))
                 :context-mode (let ((c (safe-getf opts :context)))
                                 (unless (eq c +missing+) c)))))

(defun eval-fix (form env)
  "(fix <form> [:rounds N] [:model M] [:fresh F]): evaluate <form>; when the
value is intermediate code, re-lower it in Fix mode, where the oracle chooses
reasonable defaults for whatever :reason says is missing and binds every
assumption explicitly in the generated code. An executed round returns
(fixed :source <form> :code <generated> :value <value>), so the assumptions
stay inspectable. Values that need no fix pass through unchanged; when all
rounds stay unresolved, the last intermediate code is returned."
  (destructuring-bind (subform &rest opts) (cdr form)
    (let ((rounds (let ((r (safe-getf opts :rounds)))
                    (if (eq r +missing+) 2 r)))
          (model (let ((m (safe-getf opts :model)))
                   (unless (eq m +missing+) (model-string m))))
          (fresh (let ((f (safe-getf opts :fresh)))
                   (and (not (eq f +missing+)) f)))
          (value (a-eval subform env)))
      (if (not (intermediate-code-p value))
          value
          (loop repeat rounds
                do (multiple-value-bind (v status code)
                       (let ((*oracle-fix-hint* t))
                         (oracle-eval value env :model model :fresh fresh))
                     (case status
                       (:executed
                        (return (list (usym "FIXED")
                                      :source subform :code code :value v)))
                       (:intermediate (setf value v))
                       ;; dry-run placeholder or oracle error value
                       (t (return v))))
                finally (return value))))))

;; ---------------------------------------------------------------- markdown->lisp

(defun progn-forms (code)
  "The markdown oracle replies with one (progn form...); unwrap it into the
top-level forms. A single non-progn reply is one form."
  (if (and (consp code) (symbolp (first code))
           (string= (symbol-name (first code)) "PROGN"))
      (rest code)
      (list code)))

(defun write-markdown-lisp (target forms origin-form source-label)
  "Write the converted allisp FORMS with the same provenance preamble as
generate-file, so the target can be @use'd and identifies its origin."
  (let* ((generated-at (timestamp-string))
         (source (if *current-file* (namestring *current-file*) "<one-liner>"))
         (marker (generated-by-marker source origin-form generated-at
                                      (usym "MARKDOWN->LISP"))))
    (ensure-directories-exist target)
    (with-open-file (out target :direction :output :if-exists :supersede
                                :external-format :utf-8)
      (format out ";; Generated by allisp markdown->lisp. Do not edit manually.~%")
      (format out ";; markdown source: ~a~%;; generated: ~a~%~%"
              source-label generated-at)
      (write-string +generated-by-macro-source+ out)
      (format out "~%~%~a~%" (print-sexp marker))
      (dolist (f forms)
        (format out "~%~a~%" (print-sexp (externalize f)))))
    target))

(defparameter +markdown->lisp-option-keys+ '(:from :out :model :fresh :eval))

(defun parse-markdown-args (args)
  "Split the markdown->lisp arguments into (values source-form opts).
Known option pairs may appear anywhere; the first remaining element is the
source form (+MISSING+ when absent). Extra dangling elements are ignored in
the lenient DSL spirit."
  (let ((source +missing+)
        (opts '()))
    (loop while args
          for item = (pop args)
          do (cond ((and (member item +markdown->lisp-option-keys+) args)
                    (push item opts)
                    (push (pop args) opts))
                   ((eq source +missing+) (setf source item))))
    (values source (nreverse opts))))

(defun eval-markdown-arg (form env)
  "Evaluate an input/output designator deterministically: an unbound piece
becomes an error value instead of a wasted oracle call, and its diagnostic is
rolled back so the caller reports the one meaningful error."
  (let ((errors-before (and *run* (run-errors *run*))))
    (let ((v (let ((*pure* t)) (a-eval form env))))
      (when (and (allisp-error-value-p v) *run*)
        (setf (run-errors *run*) errors-before))
      v)))

(defun eval-markdown->lisp (form env)
  "(markdown->lisp <source> [:from :file|:text|<path>] [:out <path.lisp>]
[:model M] [:fresh F] [:eval E]): convert a markdown document into allisp
forms via the oracle, prose forbidden. <source> is a path relative to the
current file (:from :file, the default) or the markdown text itself
(:from :text); :from also accepts the path itself as a string, replacing
<source>. Source and :out evaluate deterministically (never via the oracle).
The generated program is returned as a list of top-level forms and is NOT
executed; :out writes it to a .lisp file with a generated-by marker, :eval t
additionally evaluates each form in the current environment (like @use). An
unresolvable document comes back as intermediate-code."
  (multiple-value-bind (source-form opts) (parse-markdown-args (cdr form))
    (let* ((from (let ((f (safe-getf opts :from)))
                   (if (eq f +missing+) :file f)))
           (model (let ((m (safe-getf opts :model)))
                    (unless (eq m +missing+) (model-string m))))
           (fresh (let ((f (safe-getf opts :fresh)))
                    (and (not (eq f +missing+)) f)))
           (eval-p (let ((e (safe-getf opts :eval)))
                     (and (not (eq e +missing+)) e)))
           (out (let ((o (safe-getf opts :out)))
                  (unless (eq o +missing+) (eval-markdown-arg o env))))
           ;; :from "path.md" carries the path itself and replaces <source>.
           (source (if (stringp from)
                       from
                       (and (not (eq source-form +missing+))
                            (eval-markdown-arg source-form env)))))
      (when (stringp from)
        (setf from :file))
      (unless (member from '(:file :text))
        (return-from eval-markdown->lisp
          (make-error-value :invalid-markdown-source form
                            ":from must be :file, :text, or a markdown file path string")))
      (unless (stringp source)
        (return-from eval-markdown->lisp
          (make-error-value :invalid-markdown-source form
                            "markdown->lisp source must evaluate to a string; give a markdown file path as (markdown->lisp \"doc.md\" ...) or :from \"doc.md\", or inline text with :from :text")))
      (when (and out (not (and (stringp out)
                               (string-equal (pathname-type out) "lisp"))))
        (return-from eval-markdown->lisp
          (make-error-value :invalid-markdown-target form
                            ":out must be a path to a .lisp file")))
      (multiple-value-bind (text label)
          (if (eq from :text)
              (values source "<inline>")
              (let ((path (generated-path source)))
                (unless (uiop:file-exists-p path)
                  (return-from eval-markdown->lisp
                    (make-error-value :markdown-not-found form
                                      (format nil "no such file: ~a"
                                              (namestring path)))))
                (values (uiop:read-file-string path) (namestring path))))
        (let ((target (and out (generated-path out))))
          (when (and target (source-and-target-equal-p target))
            (return-from eval-markdown->lisp
              (make-error-value :generated-path-is-source form
                                "markdown->lisp cannot overwrite its source file")))
          (multiple-value-bind (code status)
              (let ((*oracle-markdown-hint* (list :label label :text text)))
                (oracle-eval form env :model model :fresh fresh :execute nil))
            (cond
              ((eq status :dry-run)
               (when target
                 (format *error-output* "~&[allisp]   would generate ~a~%"
                         (namestring target)))
               code)
              ((not (eq status :generated))
               ;; oracle failure: the error value passes through
               code)
              ((intermediate-code-p code)
               (normalize-intermediate-code code))
              (t
               (let ((forms (progn-forms code)))
                 (when target
                   (handler-case
                       (progn
                         (write-markdown-lisp target forms
                                              *current-toplevel* label)
                         (format *error-output* "~&[allisp]   generated ~a~%"
                                 (namestring target)))
                     (error (e)
                       (return-from eval-markdown->lisp
                         (make-error-value :generate-file-error form
                                           (princ-to-string e))))))
                 (when eval-p
                   (dolist (f forms)
                     (a-eval f env)))
                 forms)))))))))

;; ---------------------------------------------------------------- oracle

(defparameter +prompt-version+ "20260718-2")

(defun form-symbols (form)
  (let ((acc '()))
    (labels ((walk (x)
               (cond ((consp x) (walk (car x)) (walk (cdr x)))
                     ((and x (symbolp x) (not (eq x t)) (not (keywordp x))
                           (eq (symbol-package x) *user-package*))
                      (pushnew x acc)))))
      (walk form))
    acc))

(defun build-context (form env context-mode)
  "Definitions and bindings referenced by FORM (and the enclosing toplevel),
dependency-resolved from the environment. With CONTEXT-MODE :file, the whole
source file instead."
  (if (and (eq context-mode :file) *current-file*)
      (uiop:read-file-string *current-file*)
      (let* ((syms (sort (union (form-symbols form)
                                (form-symbols *current-toplevel*))
                         #'string< :key #'symbol-name))
             (parts '()))
        (dolist (s syms)
          (multiple-value-bind (v found) (env-lookup env s)
            (when found
              (typecase v
                (closure (when (closure-source v)
                           (push (print-sexp (closure-source v)) parts)))
                (macro-obj (when (macro-obj-source v)
                             (push (print-sexp (macro-obj-source v)) parts)))
                (function nil)          ; builtin: needs no explanation
                (t (push (print-sexp (list (usym "DEF") s (externalize v)))
                         parts))))))
        (format nil "~{~a~^~%~%~}"
                (mapcar (lambda (p) (truncate-string p 6000))
                        (nreverse parts))))))

(defun agentic-oracle-p ()
  "True when the oracle subprocess can explore the repository: the backend
runs with read-only tools enabled and there is a source file to start from.
The exploration section changes the prompt, so agentic and non-agentic calls
get separate cache entries."
  (and *run* *current-file*
       (backend-agentic (run-backend *run*))))

(defun build-oracle-prompt (form context)
  (format nil "You are the code-generation oracle of allisp, a Lisp dialect for expressing human thinking and reasoning as S-expressions.

The deterministic evaluator evaluates everything it has definitions for. It has delegated the form at the end to you because its operator has no definition. Generate Lisp CODE that computes what the author intended. You do not execute the form and must never claim that a real-world effect happened.

Rules:
1. Reply with EXACTLY ONE S-expression containing Lisp code. No markdown fences and no prose.
2. Generate an expression that a Lisp evaluator can execute. To produce list data, generate (quote (...)) or code such as (list ...); never emit a bare data list as though it had executed.
3. Use only definitions and bindings shown below, ordinary Lisp forms, and functions whose meaning is unambiguous. Do not invent an implementation for an unavailable effect such as allocation, file mutation, network access, deployment, or message sending.
4. If one executable program is not uniquely determined, return inert intermediate code in this shape:
   (intermediate-code :source (the original form) :reason (:why \"why lowering is unresolved\" :how \"specific action that can resolve it\") :constraints (...) :candidates (...))
   Both :why and :how are mandatory. :how must name the missing definition, constraint, evidence, or choice and explain the next lowering step.
   It will not be executed. Preserve enough information for a later (llm (intermediate-code ...)) pass to refine it.
5. Definitions provided below are normative. Generated code must compute a concrete result rather than restating the request.
6. Never claim an effect succeeded. Only the deterministic Lisp evaluator may execute generated code.
7. Keep natural-language strings in the language of the source (Japanese stays Japanese, English stays English).
8. Never embed a computed result inside a string literal. Any number, count, comparison, projection, or aggregate that can be derived from the bindings below must appear as an evaluable subexpression over those bindings (e.g. (* peak (expt (+ 1 growth) 4)) rather than the prose \"about 98 per minute\"), so the evaluator computes it and a changed premise changes the value. Reserve strings for genuinely non-computable judgment, and never restate in prose a value the generated code already computes.
~@[~a~]~@[~a~]~@[~a~]~@[~a~]
=== Relevant definitions and bindings ===
~a

=== Enclosing top-level form ===
~a

=== Generate Lisp code for this form ===
~a~%"
          (when *oracle-string-hint*
            (format nil "9. The caller writes the evaluated value verbatim into a non-Lisp file. Generate EXACTLY ONE double-quoted Lisp string literal containing the complete text, with internal double quotes escaped as \\\".~%"))
          (when *oracle-fix-hint*
            (format nil "
=== Fix mode ===
The target form below is inert intermediate code from a previous lowering pass. Resolve it now:
- Treat :reason (:how ...) as the instruction for what was missing.
- Where a premise, definition, or choice is missing, pick the most reasonable default; prefer an option listed in :candidates and honor every :constraints entry.
- Bind every assumption you introduce explicitly in the generated code (e.g. a let of named premises with concrete values), so no assumed value stays hidden in prose.
- Generate ONE executable Lisp expression for the deterministic evaluator. Return intermediate-code again only when no defaulted program can be justified.~%"))
          (when *oracle-markdown-hint*
            (format nil "
=== Markdown conversion mode ===
The target form asks you to convert the markdown document below into allisp source code, so the instructions it contains become processable by the deterministic evaluator. The generated code will NOT be executed here; it is kept as a program.
- Reply with exactly ONE (progn ...) whose subforms are the converted top-level allisp forms, in document order.
- Prose is forbidden: never restate the document as strings or comments. Every heading, instruction, list, table, step, and constraint becomes a structured S-expression: definitions (def / defun / defmacro), keyword-tagged plists, symbols, and numbers.
- Prefer allisp's existing forms and types first (def, defun, defmacro, let, cond, goal / solve / constraint, defer, deprecate, generate-file, keywords, plists). Where the document has domain-specific structure those forms do not capture, design a small declarative DSL for it — unbound operators are lowered later by the oracle — instead of falling back to prose.
- Keep a natural-language string only for genuinely non-computable content (e.g. a verbatim quotation), always as a short value inside a structured form.

=== Markdown document (~a) ===
~a~%"
                    (getf *oracle-markdown-hint* :label)
                    (getf *oracle-markdown-hint* :text)))
          (when (agentic-oracle-p)
            (format nil "
=== Environment ===
source file: ~a
project root: ~a
You can read this repository with the Read, Glob, and Grep tools. Before answering, gather context: read the source file around the form, follow file paths the form mentions (basis / @use / relative paths), and consult neighboring files that bear on it. Then generate Lisp code grounded in what you found. Your final reply must still be exactly one S-expression.~%"
                    (namestring *current-file*)
                    (namestring (run-root *run*))))
          (if (string= context "") "(none)" context)
          (truncate-string (print-sexp *current-toplevel*) 12000)
          (print-sexp form)))

(defun strip-code-fences (s)
  (let ((s (string-trim '(#\Space #\Newline #\Tab #\Return) s)))
    (if (and (>= (length s) 3) (string= s "```" :end1 3))
        (let ((nl (position #\Newline s))
              (end (search "```" s :from-end t)))
          (if (and nl end (> end nl))
              (string-trim '(#\Space #\Newline #\Tab #\Return)
                           (subseq s (1+ nl) end))
              s))
        s)))

(defun parse-string-response (s)
  "Read a double-quoted string with C-style escapes (\\n \\t \\r \\\" \\\\).
LLMs emit those far more often than CL's escape-next-char-literally rule, so
string responses get their own parser. Returns (values string ok-p)."
  (let ((out (make-string-output-stream))
        (i 1)
        (len (length s)))
    (loop
      (when (>= i len) (return (values nil nil)))   ; unterminated
      (let ((c (char s i)))
        (cond ((char= c #\")
               (let ((tail (subseq s (1+ i))))
                 (return
                   (if (every (lambda (x)
                                (member x '(#\Space #\Newline #\Tab #\Return)))
                              tail)
                       (values (get-output-stream-string out) t)
                       (values nil nil)))))
              ((and (char= c #\\) (< (1+ i) len))
               (let ((next (char s (1+ i))))
                 (write-char (case next
                               (#\n #\Newline)
                               (#\t #\Tab)
                               (#\r #\Return)
                               (t next))
                             out))
               (incf i 2))
              (t (write-char c out)
                 (incf i)))))))

(defun parse-oracle-response (text)
  "Extract one S-expression from TEXT. Returns (values form ok-p)."
  (let ((s (strip-code-fences text)))
    (if (and (plusp (length s)) (char= (char s 0) #\"))
        ;; A string literal may contain parens; parse it whole, C escapes and all.
        (parse-string-response s)
        (let* ((paren (position #\( s))
               (candidate (if (and paren
                                   ;; leading prose before the sexp — skip to it
                                   (string/= "" (string-trim
                                                 '(#\Space #\Newline #\Tab #\Return)
                                                 (subseq s 0 paren))))
                              (subseq s paren)
                              s)))
          (handler-case
              (let ((forms (read-allisp-string-all candidate)))
                (if (= (length forms) 1)
                    (values (first forms) t)
                    (values nil nil)))
            (error () (values nil nil)))))))

(defun symbol-resolved-p (symbol env lexical)
  (or (member symbol lexical :test #'eq)
      (nth-value 1 (env-lookup env symbol))))

(defun lambda-bound-symbols (params)
  "Return variables introduced by the supported lambda-list syntax."
  (let ((tail params)
        (result nil))
    (loop while (consp tail)
          for item = (pop tail)
          unless (and (symbolp item)
                      (plusp (length (symbol-name item)))
                      (char= (char (symbol-name item) 0) #\&))
            do (let ((name (if (consp item) (first item) item)))
                 (when (symbolp name)
                   (pushnew name result :test #'eq))))
    (when (and tail (symbolp tail))
      (pushnew tail result :test #'eq))
    (nreverse result)))

(defun generated-qq-resolved-p (form env lexical &optional (depth 1))
  (cond
    ((not (consp form)) t)
    ((eq (car form) +unquote+)
     (if (= depth 1)
         (generated-code-resolved-p (second form) env lexical)
         (generated-qq-resolved-p (second form) env lexical (1- depth))))
    ((eq (car form) +unquote-splicing+)
     (if (= depth 1)
         (generated-code-resolved-p (second form) env lexical)
         (generated-qq-resolved-p (second form) env lexical (1- depth))))
    ((eq (car form) +quasiquote+)
     (generated-qq-resolved-p (second form) env lexical (1+ depth)))
    (t
     (and (generated-qq-resolved-p (car form) env lexical depth)
          (generated-qq-resolved-p (cdr form) env lexical depth)))))

(defun generated-body-resolved-p (forms env lexical)
  (every (lambda (item) (generated-code-resolved-p item env lexical)) forms))

(defun generated-let-resolved-p (rest env lexical sequential)
  (let ((bindings (first rest))
        (body (rest rest))
        (scope lexical))
    (and
     (listp bindings)
     (every
      (lambda (binding)
        (let ((name (if (consp binding) (first binding) binding))
              (init (and (consp binding) (second binding))))
          (prog1
              (and (symbolp name)
                   (or (null init)
                       (generated-code-resolved-p init env
                                                  (if sequential scope lexical))))
            (when (and sequential (symbolp name))
              (pushnew name scope :test #'eq)))))
      bindings)
     (let ((all-names (remove-if-not
                       #'symbolp
                       (mapcar (lambda (binding)
                                 (if (consp binding) (first binding) binding))
                               bindings))))
       (generated-body-resolved-p body env (append all-names lexical))))))

(defun generated-code-resolved-p (form env &optional lexical)
  "Conservatively decide whether FORM can run without another oracle call.
This is a code gate, not a Common Lisp type checker.  It recognizes allisp's
deterministic core and rejects oracle recursion and external I/O forms."
  (cond
    ((or (null form) (eq form t) (keywordp form) (not (symbolp form)))
     (if (consp form)
         (and (proper-list-p form)
              (let* ((op (first form))
                     (name (and (symbolp op) (symbol-name op)))
                     (args (rest form)))
                (cond
                  ((and name (string= name "QUOTE")) (= (length args) 1))
                  ((and name (string= name "QUASIQUOTE"))
                   (and (= (length args) 1)
                        (generated-qq-resolved-p (first args) env lexical)))
                  ((and name (member name '("LLM" "FIX" "@USE" "%GENERATE-FILE"
                                            "MARKDOWN->LISP")
                                     :test #'string=))
                   nil)
                  ((and name (string= name "INTERMEDIATE-CODE")) nil)
                  ((and name (string= name "IF"))
                   (and (<= 2 (length args) 3)
                        (generated-body-resolved-p args env lexical)))
                  ((and name (member name '("PROGN" "AND" "OR" "WHEN" "UNLESS")
                                     :test #'string=))
                   (generated-body-resolved-p args env lexical))
                  ((and name (string= name "COND"))
                   (every (lambda (clause)
                            (and (consp clause)
                                 (let ((test (first clause)))
                                   (and (or (eq test t)
                                            (and (symbolp test)
                                                 (string= (symbol-name test)
                                                          "ELSE"))
                                            (generated-code-resolved-p
                                             test env lexical))
                                        (generated-body-resolved-p
                                         (rest clause) env lexical)))))
                          args))
                  ((and name (string= name "LET"))
                   (generated-let-resolved-p args env lexical nil))
                  ((and name (string= name "LET*"))
                   (generated-let-resolved-p args env lexical t))
                  ((and name (string= name "LAMBDA"))
                   (and (consp args) (listp (first args))
                        (generated-body-resolved-p
                         (rest args) env
                         (append (lambda-bound-symbols (first args)) lexical))))
                  ((and name (member name '("DEFUN" "DEFMACRO") :test #'string=))
                   (and (>= (length args) 3)
                        (symbolp (first args))
                        (listp (second args))
                        (generated-body-resolved-p
                         (cddr args) env
                         (append (list (first args))
                                 (lambda-bound-symbols (second args))
                                 lexical))))
                  ((and name (member name '("DEF" "DEFVAR" "DEFPARAMETER")
                                     :test #'string=))
                   (and (<= 1 (length args))
                        (symbolp (first args))
                        (or (> (length args) 2)
                            (null (rest args))
                            (generated-code-resolved-p (second args) env lexical))))
                  ((and name (string= name "DEFINE"))
                   (and (consp args)
                        (if (consp (first args))
                            (and (symbolp (first (first args)))
                                 (generated-body-resolved-p
                                  (rest args) env
                                  (append (list (first (first args)))
                                          (lambda-bound-symbols
                                           (rest (first args)))
                                          lexical)))
                            (and (symbolp (first args))
                                 (or (null (rest args))
                                     (generated-code-resolved-p
                                      (second args) env lexical))))))
                  ((and name (member name '("SETQ" "SETF") :test #'string=))
                   (and (evenp (length args))
                        (loop for (place value) on args by #'cddr
                              always (and (symbolp place)
                                          (symbol-resolved-p place env lexical)
                                          (generated-code-resolved-p
                                           value env lexical)))))
                  ((and name (member name '("INCF" "DECF") :test #'string=))
                   (and (<= 1 (length args) 2)
                        (symbolp (first args))
                        (symbol-resolved-p (first args) env lexical)
                        (or (null (rest args))
                            (generated-code-resolved-p
                             (second args) env lexical))))
                  ((and name (string= name "PUSH"))
                   (and (= (length args) 2)
                        (generated-code-resolved-p (first args) env lexical)
                        (symbolp (second args))
                        (symbol-resolved-p (second args) env lexical)))
                  ((and name (string= name "DEFER"))
                   (generated-body-resolved-p (cddr args) env lexical))
                  ((and name (member name '("PURE" "DEPRECATE")
                                     :test #'string=))
                   (generated-body-resolved-p args env lexical))
                  ((and (symbolp op) (symbol-resolved-p op env lexical))
                   (generated-body-resolved-p args env lexical))
                  ((consp op)
                   (and (generated-code-resolved-p op env lexical)
                        (generated-body-resolved-p args env lexical)))
                  (t nil))))
         t))
    ((symbolp form) (symbol-resolved-p form env lexical))
    (t t)))

(defun intermediate-code-p (form)
  (and (consp form)
       (symbolp (first form))
       (string= (symbol-name (first form)) "INTERMEDIATE-CODE")))

(defparameter +default-intermediate-how+
  "Define the missing operators or replace them with available deterministic Lisp code, add any missing constraints or candidates, then run (llm (intermediate-code ...)) again.")

(defun normalize-intermediate-reason (reason)
  "Return a reason plist that always contains actionable :WHY and :HOW text.
String reasons from the pre-structured format remain readable as :WHY."
  (if (consp reason)
      (let ((why (safe-getf reason :why))
            (how (safe-getf reason :how)))
        (list :why (if (eq why +missing+)
                       "lowering is unresolved"
                       why)
              :how (if (eq how +missing+)
                       +default-intermediate-how+
                       how)))
      (list :why (if (or (null reason) (eq reason +missing+))
                     "lowering is unresolved"
                     reason)
            :how +default-intermediate-how+)))

(defun normalize-intermediate-code (form)
  "Normalize legacy or incomplete INTERMEDIATE-CODE to the current contract."
  (let* ((copy (copy-tree form))
         (reason (safe-getf (rest copy) :reason)))
    (setf (getf (cdr copy) :reason)
          (normalize-intermediate-reason reason))
    copy))

(defun unresolved-generated-code (source generated)
  (list (usym "INTERMEDIATE-CODE")
        :source source
        :reason
        (list :why
              "generated code contains operators or references that the deterministic evaluator cannot resolve"
              :how
              "Define the unresolved operators in allisp or replace them with available deterministic Lisp code, then pass this intermediate code to llm for another lowering step.")
        :generated generated))

(defun allisp-error-value-p (value)
  (and (consp value)
       (eq (first value) (usym "ERROR"))))

(defun materialize-oracle-code (source generated env)
  "Execute GENERATED only when it is wholly deterministic.  Otherwise retain
it as inert intermediate code for a later explicit oracle pass."
  (cond
    ((intermediate-code-p generated)
     (values (normalize-intermediate-code generated) :intermediate))
    ((not (generated-code-resolved-p generated env))
     (values (unresolved-generated-code source generated) :intermediate))
    (t
     (let ((*pure* t)
           (errors-before (and *run* (run-errors *run*))))
       (handler-case
           (let ((value (a-eval generated env)))
             (if (allisp-error-value-p value)
                 (progn
                   ;; A conservative static check can still encounter an
                   ;; unresolved macro expansion at runtime. It is staging,
                   ;; not a program error, so retain the code and roll back
                   ;; the diagnostic added by MAKE-ERROR-VALUE.
                   (when *run*
                     (setf (run-errors *run*) errors-before))
                   (values (unresolved-generated-code source generated)
                           :intermediate))
                 (values value :executed)))
         (error ()
           (when *run*
             (setf (run-errors *run*) errors-before))
           (values (unresolved-generated-code source generated)
                   :intermediate)))))))

(defun oracle-eval (form env &key model fresh context-mode (execute t))
  (unless *run*
    (return-from oracle-eval
      (make-error-value :no-run form "oracle call outside of a run")))
  (let* ((n (incf (run-n *run*)))
         (model (or model (run-model *run*)))
         (context (build-context form env context-mode))
         (prompt (build-oracle-prompt form context))
         (hash (sha256-hex (format nil "~a~%~a~%~a" +prompt-version+ model prompt)))
         (root (run-root *run*))
         (cached (unless (or fresh (run-refresh *run*))
                   (cache-get root hash))))
    (cond
      (cached
       (incf (run-hits *run*))
       (let ((code (or (getf cached :code) (getf cached :value))))
         (multiple-value-bind (value status)
             (if execute
                 (materialize-oracle-code form code env)
                 (values code :generated))
           (log-oracle n :hit model form 0 status)
           (push (list :n n :cache :hit :model model :hash hash
                       :form form :code code :status status :value value)
                 (run-trace *run*))
           (values value status code))))
      ((run-dry-run *run*)
       (log-oracle n :dry-run model form 0)
       (push (list :n n :cache :would-miss :model model :hash hash :form form)
             (run-trace *run*))
       (values (list (usym "ORACLE-PENDING") (subseq hash 0 12)) :dry-run nil))
      (t
       (call-oracle n form prompt hash model root env execute)))))

(defun call-oracle (n form prompt hash model root env execute)
  (let ((start (get-internal-real-time)))
    (loop for attempt from 1 to 3
          for p = prompt then (concatenate
                               'string prompt
                               (format nil "~%REMINDER: your previous reply could not be parsed. Reply with exactly ONE S-expression and nothing else.~%"))
          do (multiple-value-bind (raw call-ok)
                 (handler-case (values (backend-complete (run-backend *run*) p
                                                         :model model
                                                         :directory root)
                                       t)
                   (error (e) (values (princ-to-string e) nil)))
               (when call-ok
                 (multiple-value-bind (code parse-ok) (parse-oracle-response raw)
                   (when parse-ok
                     (let ((secs (/ (- (get-internal-real-time) start)
                                    internal-time-units-per-second)))
                       (incf (run-misses *run*))
                       (cache-put root hash
                                  (list :hash hash
                                        :prompt-version +prompt-version+
                                        :model model
                                        :timestamp (timestamp-string)
                                        :form form
                                        :code code
                                        :raw raw))
                       (multiple-value-bind (value status)
                           (if execute
                               (materialize-oracle-code form code env)
                               (values code :generated))
                         (log-oracle n :miss model form secs status)
                         (push (list :n n :cache :miss :model model :hash hash
                                     :seconds (float secs) :form form :code code
                                     :status status :value value)
                               (run-trace *run*))
                         (return-from call-oracle
                           (values value status code)))))))
               (when (= attempt 3)
                 (push (list :n n :cache :failed :model model :hash hash
                             :form form :detail raw)
                       (run-trace *run*))
                 (return-from call-oracle
                   (make-error-value
                    :oracle-failure form
                    (format nil "no parseable S-expression after 3 attempts: ~a"
                            (truncate-string (or raw "") 400)))))))))

(defun log-oracle (n kind model form secs &optional status)
  (format *error-output* "~&[allisp]   oracle #~a ~(~a~) ~a ~a~@[ → ~(~a~)~]~@[ (~,1fs)~]~%"
          n kind model (form-summary form 60) status
          (when (and secs (> secs 0)) (float secs)))
  (force-output *error-output*))

;; ---------------------------------------------------------------- externalize

(defun externalize (v)
  "Replace host objects with readable placeholders for result/trace/cache files."
  (typecase v
    (closure (list (usym "CLOSURE") (or (closure-name v) (usym "ANONYMOUS"))))
    (macro-obj (list (usym "MACRO") (macro-obj-name v)))
    (managed-memory-block
     (list :resource :memory-block
           :status :allocated
           :element-type (managed-memory-block-element-type v)
           :integer-width (managed-memory-block-integer-width v)
           :length (managed-memory-block-length v)
           :initialization :tracked
           :initialized-count
           (count 1 (managed-memory-block-initialized v))
           :lifetime :current-process))
    (function (list (usym "BUILTIN")))
    (hash-table (list (usym "HASH-TABLE")))
    (cons (cons (externalize (car v)) (externalize (cdr v))))
    (t v)))

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
and re-fix passes get their own cache entries.")

(defvar *oracle-markdown-hint* nil
  "When bound to (:label L :text T), the oracle prompt gains a markdown
conversion section: the document T is to be converted into allisp forms with
prose forbidden. Bound by MARKDOWN->LISP. The document is part of the prompt,
so each document revision gets its own cache entry.")

(defvar *oracle-spec-predicate-hint* nil
  "When true, the oracle prompt gains a spec-predicate section: the target
form carries ONE invariant clause plus the signature of a defspec, and the
oracle must lower it to a (lambda (in out) ...) predicate. Bound by
CHECK-SPEC per clause. The target form contains only that clause, so each
clause gets its own cache entry and editing one clause re-lowers only its
predicate.")

(defvar *oracle-context-predicate-hint* nil
  "When true, lower one example's normative natural-language context to a
(lambda (in out) ...) predicate.  The synthetic form contains no concrete
example values, so the predicate is reusable and safely cacheable.")

(defvar *oracle-probe-hint* nil
  "When true, the oracle prompt gains a spec-audit section: the referenced
spec is to be searched for unspecified corners and conflicting invariant
clauses, answered as one (spec-findings ...) of inert intermediate-code
entries. Bound by PROBE-SPEC; a list value restricts the audit to the named
clauses (and, being part of the prompt, gets its own cache entry).")

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
    "@USE" "LLM" "PURE" "FIX" "RE-FIX" "DEFER" "DEPRECATE" "RESULT" "INTERMEDIATE-CODE"
    "MARKDOWN->LISP" "PROBE-SPEC" "VERIFY"
    "%GENERATE-FILE" "%GOAL" "%SOLVE" "%CONSTRAINT"
    "%DEFSPEC" "%EXAMPLE" "%SPEC-CHECK" "%DERIVE"))

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
        ((is "RE-FIX") (eval-re-fix form env))
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
        ((is "%DEFSPEC") (eval-defspec form env))
        ((is "%EXAMPLE") (eval-example form env))
        ((is "%SPEC-CHECK") (eval-spec-check form env))
        ((is "%DERIVE") (eval-derive form env))
        ((is "PROBE-SPEC") (eval-probe-spec form env))
        ((is "VERIFY") (eval-verify form env))
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

(defparameter +defspec-macro-source+
  "(defmacro defspec (name &body clauses)
  `(%defspec (quote ,name) (quote ,clauses)))")

(defparameter +example-macro-source+
  "(defmacro example (spec &body fields)
  `(%example (quote ,spec) (quote ,fields)))")

(defparameter +check-spec-macro-source+
  "(defmacro check-spec (name &body opts)
  `(%spec-check (quote ,name) (quote ,opts)))")

(defparameter +derive-macro-source+
  "(defmacro derive (path &body opts)
  `(%derive ,path (quote ,opts) (quote (derive ,path ,@opts))))")

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
                        +solve-macro-source+
                        +defspec-macro-source+
                        +example-macro-source+
                        +check-spec-macro-source+
                        +derive-macro-source+) env)
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

(defparameter +result-format-version+ 3)

(defun def-form-name (form)
  "Return the defined name when FORM is a data-definition form whose value a
result file can restore: def / defvar / defparameter, or the variable form of
define. Function definitions (defun, defmacro, define with a lambda list) are
excluded because closures do not survive externalization."
  (when (and (consp form) (symbolp (first form)) (symbolp (second form)))
    (let ((head (symbol-name (first form))))
      (when (or (string= head "DEF") (string= head "DEFVAR")
                (string= head "DEFPARAMETER") (string= head "DEFINE")
                (string= head "DEFSPEC"))
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
  "Replay a (result :v 3 :n K :form F :value V) record from a .result.lisp
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
    (when (and (integerp version) (>= version 3) source *run*)
      ;; Preserve source-definition metadata even for closures that cannot be
      ;; externalized. This is enough to reconstruct example dependency
      ;; hashes and proof certificates without pretending the closure itself
      ;; was restored.
      (multiple-value-bind (defined kind) (source-definition-info source)
        (when defined
          (let ((record (list :name defined :kind kind :form source
                              :file *current-file*
                              :order (run-toplevel-n *run*)
                              :value value)))
            (setf (gethash defined (run-definitions *run*)) record)
            (when (eq kind :defspec)
              (setf (gethash defined (run-specs *run*)) record)))))
      (when (and (consp source) (symbolp (first source)))
        (let ((head (symbol-name (first source))))
          (cond
            ((string= head "EXAMPLE")
             (let ((*current-toplevel* source))
               (eval-example
                (list (usym "%EXAMPLE")
                      (list +quote+ (second source))
                      (list +quote+ (cddr source)))
                env)))
            ((and (string= head "CHECK-SPEC")
                  (consp value)
                  (symbolp (first value))
                  (string= (symbol-name (first value)) "SPEC-CHECK"))
             (let* ((name (second source))
                    (record (gethash name (run-specs *run*)))
                    (spec (and record (spec-property record :value)))
                    (hash (and spec (current-spec-hash name spec)))
                    (cert (cdr value)))
               (when (and hash
                          (certification-current-p cert name hash)
                          (member (spec-property cert :status)
                                  '(:passed :skipped)))
                 (setf (gethash name (run-check-certifications *run*))
                       (append (copy-list cert) (list :report value))))))
            ((and (string= head "PROBE-SPEC")
                  (consp value)
                  (symbolp (first value))
                  (string= (symbol-name (first value)) "SPEC-FINDINGS"))
             (let* ((name (second source))
                    (record (gethash name (run-specs *run*)))
                    (spec (and record (spec-property record :value)))
                    (hash (and spec (current-spec-hash name spec)))
                    (cert (cdr value)))
               (when (and hash
                          (certification-current-p cert name hash)
                          (eq (spec-property cert :status) :passed))
                 (setf (gethash name (run-probe-certifications *run*))
                       (append (copy-list cert) (list :report value))))))))))
    (env-define env (usym "LAST-RESULT") value)
    value))

(defun source-definition-info (form)
  "Return (values NAME KIND) for source-local binding forms."
  (when (and (consp form) (symbolp (first form)))
    (let ((head (symbol-name (first form)))
          (arg (second form)))
      (cond
        ((member head '("DEFUN" "DEFMACRO" "DEF" "DEFVAR" "DEFPARAMETER"
                        "DEFSPEC")
                 :test #'string=)
         (when (symbolp arg)
           (values arg (intern head :keyword))))
        ((string= head "DEFINE")
         (cond ((symbolp arg) (values arg :define-value))
               ((and (consp arg) (symbolp (first arg)))
                (values (first arg) :define-function))))))))

(defun same-source-file-p (a b)
  (or (and (null a) (null b))
      (and a b (equal (namestring a) (namestring b)))))

(defun record-toplevel-definition (form value)
  (when *run*
    (multiple-value-bind (name kind) (source-definition-info form)
      (when name
        (let ((record (list :name name :kind kind :form form
                            :file *current-file*
                            :order (run-toplevel-n *run*)
                            :value value)))
          (setf (gethash name (run-definitions *run*)) record)
          (when (eq kind :defspec)
            (setf (gethash name (run-specs *run*)) record)))))))

(defun eval-toplevel-form (form env)
  (when *run* (incf (run-toplevel-n *run*)))
  (let ((*current-toplevel* form))
    (handler-case
        (let ((value (a-eval form env)))
          (unless (allisp-error-value-p value)
            (record-toplevel-definition form value))
          value)
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

(defparameter +default-re-fix-rounds+ 16
  "Maximum Fix-mode lowering attempts for each intermediate-code node visited
by RE-FIX. The bound prevents a changing but never resolving oracle response
from looping forever.")

(defun fixed-value-p (value)
  (and (consp value)
       (symbolp (first value))
       (string= (symbol-name (first value)) "FIXED")))

(defun re-fix-intermediate (value env rounds model fresh)
  "Repeatedly lower one intermediate VALUE, then recursively repair any
intermediate-code contained in the executed value. The FIXED record keeps the
successful code inspectable; its source and code are deliberately not walked."
  (let ((source value))
    (loop repeat rounds
          do (multiple-value-bind (v status code)
                 (let ((*oracle-fix-hint* t))
                   (oracle-eval value env :model model :fresh fresh))
               (case status
                 (:executed
                  (return
                    (list (usym "FIXED")
                          :source source
                          :code code
                          :value (re-fix-value v env rounds model fresh))))
                 (:intermediate (setf value v))
                 ;; dry-run placeholder or oracle error value
                 (t (return v))))
          finally (return value))))

(defun re-fix-value (value env rounds model fresh)
  "Walk VALUE as data and repair every intermediate-code node.
Existing FIXED audit records are preserved and only their :VALUE payload is
walked, otherwise their inert :SOURCE would be repaired again forever."
  (cond
    ((intermediate-code-p value)
     (re-fix-intermediate value env rounds model fresh))
    ((fixed-value-p value)
     (let* ((copy (copy-tree value))
            (payload (safe-getf (rest copy) :value)))
       (unless (eq payload +missing+)
         (setf (getf (cdr copy) :value)
               (re-fix-value payload env rounds model fresh)))
       copy))
    ((consp value)
     (cons (re-fix-value (car value) env rounds model fresh)
           (re-fix-value (cdr value) env rounds model fresh)))
    (t value)))

(defun eval-re-fix (form env)
  "(re-fix <form> [:rounds N] [:model M] [:fresh F]): evaluate <form>, walk
the resulting value recursively, and repeatedly apply Fix-mode lowering to
every intermediate-code node until it executes or N attempts are exhausted.
N defaults to 16 per node. Successful nodes become inspectable FIXED records."
  (destructuring-bind (subform &rest opts) (cdr form)
    (let ((rounds (let ((r (safe-getf opts :rounds)))
                    (if (eq r +missing+) +default-re-fix-rounds+ r)))
          (model (let ((m (safe-getf opts :model)))
                   (unless (eq m +missing+) (model-string m))))
          (fresh (let ((f (safe-getf opts :fresh)))
                   (and (not (eq f +missing+)) f))))
      (re-fix-value (a-eval subform env) env rounds model fresh))))

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

;; ---------------------------------------------------------------- spec-driven forms

(defparameter +example-context-limit+ 4000)
(defparameter +spec-context-limit+ 16000)
(defparameter +example-allowed-fields+
  '(:name :in :out :context :covers :depends-on))

(defun plist-schema-error (plist allowed required)
  "Return a short schema error string for PLIST, or NIL."
  (cond
    ((not (proper-list-p plist)) "example fields must be a proper list")
    ((oddp (length plist)) "example fields must form a keyword plist")
    (t
     (let ((seen '()))
       (loop for key in plist by #'cddr
             do (unless (keywordp key)
                  (return-from plist-schema-error
                    (format nil "example field ~a is not a keyword" key)))
                (unless (member key allowed)
                  (return-from plist-schema-error
                    (format nil "unknown example field ~a" key)))
                (when (member key seen)
                  (return-from plist-schema-error
                    (format nil "example field ~a appears twice" key)))
                (push key seen))
       (dolist (key required)
         (unless (member key seen)
           (return-from plist-schema-error
             (format nil "example field ~a is required" key))))
       nil))))

(defun unique-list-p (items &key (test #'eql))
  (= (length items) (length (remove-duplicates items :test test))))

(defun definition-record (name)
  (and *run* (gethash name (run-definitions *run*))))

(defun spec-direct-dependencies (spec)
  (remove-duplicates
   (loop for example in (spec-example-list spec)
         append (or (spec-property example :depends-on) '()))
   :test #'eq))

(defun spec-direct-spec-dependencies (spec)
  (remove-if-not
   (lambda (name)
     (eq (spec-property (definition-record name) :kind) :defspec))
   (spec-direct-dependencies spec)))

(defun spec-dependency-reaches-p (start goal &optional seen)
  (cond
    ((eq start goal) t)
    ((member start seen :test #'eq) nil)
    (t
     (let ((record (and *run* (gethash start (run-specs *run*)))))
       (and record
            (some (lambda (next)
                    (spec-dependency-reaches-p next goal (cons start seen)))
                  (spec-direct-spec-dependencies
                   (spec-property record :value))))))))

(defun dependency-closure-records (spec-name spec)
  "Source-ordered transitive closure of definitions explicitly reachable
from SPEC's examples. Symbols in a dependency's source form are followed
only when they resolve to another source-local definition."
  (let ((seen (make-hash-table :test #'eq))
        (records '())
        (origin-record (and *run* (gethash spec-name (run-specs *run*)))))
    (labels ((visit (name)
               (unless (or (eq name spec-name) (gethash name seen))
                 (setf (gethash name seen) t)
                 (let ((record (definition-record name)))
                   (when record
                     (push record records)
                     (dolist (sym (form-symbols
                                   (if (eq (spec-property record :kind) :defspec)
                                       (spec-property record :value)
                                       (spec-property record :form))))
                       (let ((child (definition-record sym)))
                         (when (and child
                                    (same-source-file-p
                                     (spec-property child :file)
                                     (spec-property origin-record :file)))
                           (visit sym))))
                     (when (eq (spec-property record :kind) :defspec)
                       (dolist (child
                                (spec-direct-dependencies
                                 (spec-property record :value)))
                         (visit child))))))))
      (dolist (name (spec-direct-dependencies spec)) (visit name)))
    (sort records #'< :key (lambda (r) (or (spec-property r :order) 0)))))

(defun current-spec-hash (name spec)
  "Hash canonical spec data plus normalized transitive dependency sources."
  (sha256-hex
   (print-sexp
    (list :spec spec
          :dependencies
          (mapcar
           (lambda (record)
             (list (spec-property record :name)
                   (if (eq (spec-property record :kind) :defspec)
                       (spec-property record :value)
                       (spec-property record :form))))
           (dependency-closure-records name spec)))
    :pretty nil)))

(defun validate-example-dependencies (origin target fields)
  (let* ((raw-deps (safe-getf fields :depends-on))
         (deps (unless (eq raw-deps +missing+) raw-deps))
        (target-record (and *run* (gethash target (run-specs *run*)))))
    (unless (eq raw-deps +missing+)
      (unless (and (proper-list-p deps) deps
                   (every (lambda (x)
                            (and (symbolp x) x (not (keywordp x))))
                          deps)
                   (unique-list-p deps :test #'eq))
        (return-from validate-example-dependencies
          (make-error-value
           :example-invalid-dependency origin
           ":depends-on must be a nonempty list of unique, non-keyword symbols")))
      (dolist (name deps)
        (when (eq name target)
          (return-from validate-example-dependencies
            (make-error-value :spec-dependency-cycle origin
                              "a spec cannot depend on itself")))
        (let ((record (definition-record name)))
          (unless (and record target-record
                       (same-source-file-p (spec-property record :file)
                                           (spec-property target-record :file))
                       (< (or (spec-property record :order) 0)
                          (run-toplevel-n *run*)))
            (return-from validate-example-dependencies
              (make-error-value
               :example-dependency-not-found origin
               (format nil "~a must be defined earlier in the same source file"
                       name)))))
        (when (and (eq (spec-property (definition-record name) :kind) :defspec)
                   (spec-dependency-reaches-p name target))
          (return-from validate-example-dependencies
            (make-error-value :spec-dependency-cycle origin
                              (format nil "adding ~a -> ~a creates a defspec cycle"
                                      target name))))))
    nil))

(defun eval-example (form env)
  "(example SPEC :name ... :in ... :out ... :context ...): append one
unevaluated, named example to a preceding same-file defspec."
  (destructuring-bind (op spec-form fields-form) form
    (declare (ignore op))
    (let* ((name (a-eval spec-form env))
           (fields (a-eval fields-form env))
           (origin (list* (usym "EXAMPLE") name fields)))
      (unless (and (consp *current-toplevel*)
                   (symbolp (first *current-toplevel*))
                   (string= (symbol-name (first *current-toplevel*)) "EXAMPLE"))
        (return-from eval-example
          (make-error-value :example-not-toplevel origin
                            "example is allowed only as a top-level form")))
      (let ((schema (plist-schema-error
                     fields +example-allowed-fields+
                     '(:name :in :out :context))))
        (when schema
          (return-from eval-example
            (make-error-value :example-malformed origin schema))))
      (let* ((record (and *run* (gethash name (run-specs *run*))))
             (context (spec-property fields :context))
             (example-name (spec-property fields :name)))
        (unless (and record
                     (same-source-file-p (spec-property record :file)
                                         *current-file*))
          (return-from eval-example
            (make-error-value
             :example-spec-not-found origin
             (format nil "~a must be a preceding defspec in the same source file"
                     name))))
        (when (and *run* (gethash name (run-derived-specs *run*)))
          (return-from eval-example
            (make-error-value :example-after-derive origin
                              "examples are append-only before the first derive")))
        (unless (keywordp example-name)
          (return-from eval-example
            (make-error-value :example-invalid-name origin
                              ":name must be a keyword")))
        (unless (and (stringp context)
                     (> (length (string-trim '(#\Space #\Tab #\Newline #\Return)
                                             context))
                        0))
          (return-from eval-example
            (make-error-value :example-invalid-context origin
                              ":context must be a nonempty string")))
        (when (> (length context) +example-context-limit+)
          (return-from eval-example
            (make-error-value
             :example-context-too-large origin
             (format nil ":context exceeds ~a Unicode characters"
                     +example-context-limit+))))
        (let* ((spec (spec-property record :value))
               (examples (spec-example-list spec))
               (raw-covers (safe-getf fields :covers))
               (covers (unless (eq raw-covers +missing+) raw-covers)))
          (when (spec-example-by-name spec example-name)
            (return-from eval-example
              (make-error-value :example-duplicate-name origin
                                (format nil "example name ~a already exists"
                                        example-name))))
          (unless (eq raw-covers +missing+)
            (unless (and (proper-list-p covers) covers
                         (every #'keywordp covers)
                         (unique-list-p covers :test #'eq)
                         (every (lambda (key)
                                  (member key (spec-invariant-names spec)
                                          :test #'eq))
                                covers))
              (return-from eval-example
                (make-error-value
                 :example-invalid-covers origin
                 ":covers must be a nonempty unique list of invariant names"))))
          (when (> (+ (length context)
                      (reduce #'+ examples
                              :key (lambda (ex)
                                     (length (spec-property ex :context)))
                              :initial-value 0))
                   +spec-context-limit+)
            (return-from eval-example
              (make-error-value
               :spec-context-too-large origin
               (format nil "total example context exceeds ~a Unicode characters"
                       +spec-context-limit+))))
          (let ((dependency-error
                  (validate-example-dependencies origin name fields)))
            (when dependency-error
              (return-from eval-example dependency-error)))
          (let* ((stored (copy-tree fields))
                 (updated (replace-spec-examples
                           spec (append examples (list stored)))))
            (setf (getf record :value) updated)
            (env-define env name updated)
            (when *run*
              (remhash name (run-check-certifications *run*))
              (remhash name (run-probe-certifications *run*)))
            (list (usym "EXAMPLE-ADDED")
                  :spec name
                  :example example-name
                  :data stored)))))))

(defun eval-defspec (form env)
  "(defspec name . clauses): bind NAME to a first-class specification.
Clauses are never evaluated (like the multi-form def, they are prose-like
data), but their shape is checked deterministically before binding: duplicate
top-level clauses, duplicate invariant names, and malformed invariants or
examples become first-class error values and nothing is bound. Returns the
bound value (the normalized clause plist), so result files record the whole
spec and replay restores it by name."
  (destructuring-bind (op name-form clauses-form) form
    (declare (ignore op))
    (let* ((name (a-eval name-form env))
           (clauses (a-eval clauses-form env))
           (origin (list* (usym "DEFSPEC") name clauses)))
      (unless (and name (symbolp name) (not (keywordp name)))
        (return-from eval-defspec
          (make-error-value :spec-malformed-clause origin
                            "defspec name must be a symbol")))
      (let ((previous (and *run* (gethash name (run-specs *run*)))))
        (when (and previous
                   (same-source-file-p (spec-property previous :file)
                                       *current-file*))
          (return-from eval-defspec
            (make-error-value :spec-redefined origin
                              "a defspec name may be defined only once per source file"))))
      (let ((err (validate-spec-clauses origin clauses)))
        (when err (return-from eval-defspec err)))
      (let ((value (normalize-spec-clauses name clauses)))
        (env-define env name value)
        value))))

(defun spec-apply-predicate (pred in out env)
  "Apply a lowered invariant predicate to one example, deterministically.
Returns (values satisfied-p errored-p); diagnostics from a predicate that
fails to run are rolled back — the caller reports it as a skipped check."
  (declare (ignore env))
  (let ((*pure* t)
        (errors-before (and *run* (run-errors *run*))))
    (handler-case
        (let ((v (a-apply pred (list in out))))
          (if (allisp-error-value-p v)
              (progn
                (when *run* (setf (run-errors *run*) errors-before))
                (values nil t))
              (values (and v t) nil)))
      (error ()
        (when *run* (setf (run-errors *run*) errors-before))
        (values nil t)))))

(defun effective-model (model)
  (or model (and *run* (run-model *run*)) "sonnet"))

(defun certification-metadata (name hash model status)
  (list :spec name :spec-sha256 hash
        :evaluator-version +evaluator-version+
        :prompt-version +prompt-version+
        :model (effective-model model)
        :status status))

(defun record-check-certification (name hash model status report)
  (when *run*
    (setf (gethash name (run-check-certifications *run*))
          (append (certification-metadata name hash model status)
                  (list :report report)))))

(defun dependency-prompt-data (name spec)
  (mapcar
   (lambda (record)
     (list (spec-property record :name)
           (if (eq (spec-property record :kind) :defspec)
               (spec-property record :value)
               (spec-property record :form))))
   (dependency-closure-records name spec)))

(defun eval-spec-check (form env)
  "(check-spec name [:model M] [:fresh F]): lower each invariant clause of
the spec bound to NAME into a (lambda (in out) ...) predicate — one oracle
call per clause, each cached under a prompt that contains only that clause
and the signature — then apply every predicate to every example with no
further LLM call. Contradictions between clauses surface as violations the
moment an example touches them. Clauses that cannot be decided from a single
(in out) pair come back as intermediate-code and are recorded under
:skipped. Violations turn the whole check into a first-class error value."
  (destructuring-bind (op name-form opts-form) form
    (declare (ignore op))
    (let* ((name (a-eval name-form env))
           (opts (a-eval opts-form env))
           (origin (list* (usym "CHECK-SPEC") name opts))
           (model (let ((m (safe-getf opts :model)))
                    (unless (eq m +missing+) (model-string m))))
           (fresh (let ((f (safe-getf opts :fresh)))
                    (and (not (eq f +missing+)) f))))
      (multiple-value-bind (spec found) (env-lookup env name)
        (unless (and found (consp spec))
          (return-from eval-spec-check
            (make-error-value :spec-not-found origin
                              (format nil "~a is not bound to a spec" name))))
        (let ((signature (spec-property spec :signature))
              (invariants (or (spec-property spec :invariants) '()))
              (examples (spec-example-list spec))
              (invariant-checked 0)
              (context-checked 0)
              (violations '())
              (skipped '())
              (failures '()))
          (when (null examples)
            (return-from eval-spec-check
              (make-error-value :spec-no-examples origin
                                "check-spec requires at least one top-level example")))
          (dolist (clause invariants)
            (if (not (and (consp clause) (keywordp (first clause))))
                (push (list :kind :invariant :invariant clause
                            :reason (list :why "malformed invariant clause"
                                          :how "write the clause as (:name \"one sentence\")"))
                      skipped)
                (let* ((cname (first clause))
                       (synth (list (usym "SPEC-INVARIANT-PREDICATE")
                                    :signature signature
                                    :invariant clause)))
                  (multiple-value-bind (value status)
                      ;; The synthetic form carries only this clause and the
                      ;; signature, and becomes its own toplevel for context
                      ;; purposes, so its cache key ignores the other clauses:
                      ;; editing one clause re-lowers only its own predicate.
                      (let ((*oracle-spec-predicate-hint* t)
                            (*current-toplevel* synth))
                        (oracle-eval synth env :model model :fresh fresh))
                    (cond
                      ((and (eq status :executed)
                            (or (closure-p value) (functionp value)))
                       (dolist (ex examples)
                         (let ((in (spec-property ex :in))
                               (out (spec-property ex :out)))
                           (incf invariant-checked)
                           (multiple-value-bind (ok errored)
                               (spec-apply-predicate value in out env)
                             (cond
                               (errored
                                (push (list :kind :invariant
                                            :invariant cname :example ex
                                            :reason (list :why "predicate raised an error on this example"
                                                          :how "re-run with :fresh t or rephrase the invariant clause"))
                                      failures))
                               ((not ok)
                                (push (list :kind :invariant
                                            :invariant cname :example ex)
                                      violations)))))))
                      ((eq status :executed)
                       (push (list :kind :invariant :invariant cname
                                   :reason (list :why "predicate lowering did not produce a function"
                                                 :how "re-run with :fresh t or rephrase the invariant clause"))
                             skipped))
                      ((eq status :intermediate)
                       (push (list :kind :invariant :invariant cname
                                   :reason (let ((r (safe-getf (rest value) :reason)))
                                             (unless (eq r +missing+) r)))
                             skipped))
                      ((eq status :dry-run)
                       (push (list :kind :invariant :invariant cname
                                   :reason (list :why "dry-run: predicate not lowered"
                                                 :how "run without --dry-run"))
                             skipped))
                      (t                ; oracle failure: error value recorded
                       (push (list :kind :invariant :invariant cname
                                   :reason (list :why "oracle failure while lowering the predicate"
                                                 :how "see the error value in this run"))
                             failures)))))))
          ;; Context is normative, but deliberately lowered separately from
          ;; invariant predicates.  Concrete :in/:out values are absent from
          ;; SYNTH, preventing an example-specific predicate from being
          ;; overfit and allowing identical context/covers to share a cache.
          (let ((local-cache (make-hash-table :test #'equal)))
            (dolist (ex examples)
              (let* ((covers (spec-property ex :covers))
                     (covered-clauses
                       (when covers
                         (remove-if-not
                          (lambda (clause) (member (first clause) covers :test #'eq))
                          invariants)))
                     (synth
                       (list (usym "SPEC-CONTEXT-PREDICATE")
                             :signature signature
                             :context (spec-property ex :context)
                             :covered-invariants covered-clauses
                             :dependencies
                             (dependency-prompt-data
                              name (replace-spec-examples spec (list ex)))))
                     (cached (gethash synth local-cache))
                     value status)
                (if cached
                    (setf value (first cached) status (second cached))
                    (progn
                      (multiple-value-setq (value status)
                        (let ((*oracle-context-predicate-hint* t)
                              (*current-toplevel* synth))
                          (oracle-eval synth env :model model :fresh fresh)))
                      (setf (gethash synth local-cache) (list value status))))
                (cond
                  ((and (eq status :executed)
                        (or (closure-p value) (functionp value)))
                   (incf context-checked)
                   (multiple-value-bind (ok errored)
                       (spec-apply-predicate value
                                             (spec-property ex :in)
                                             (spec-property ex :out)
                                             env)
                     (cond
                       (errored
                        (push (list :kind :context
                                    :example (spec-property ex :name)
                                    :reason
                                    (list :why "context predicate raised an error"
                                          :how "re-run with :fresh t or clarify the context"))
                              failures))
                       ((not ok)
                        (push (list :kind :context
                                    :example (spec-property ex :name))
                              violations)))))
                  ((eq status :dry-run)
                   (push (list :kind :context
                               :example (spec-property ex :name)
                               :reason
                               (list :why "dry-run: context predicate not lowered"
                                     :how "run without --dry-run"))
                         skipped))
                  ((eq status :intermediate)
                   (push (list :kind :context
                               :example (spec-property ex :name)
                               :reason (let ((r (safe-getf (rest value) :reason)))
                                         (unless (eq r +missing+) r)))
                         skipped))
                  (t
                   (push (list :kind :context
                               :example (spec-property ex :name)
                               :reason
                               (list :why "oracle failure while lowering the context predicate"
                                     :how "see the error value in this run"))
                         failures))))))
          (let* ((hash (current-spec-hash name spec))
                 (violations (nreverse violations))
                 (skipped (nreverse skipped))
                 (failures (nreverse failures))
                 (status (cond
                           ((and *run* (run-dry-run *run*)) :would-check)
                           (failures :errors)
                           (violations :violations)
                           (skipped :skipped)
                           (t :passed)))
                 (report
                   (append
                    (list (usym "SPEC-CHECK")
                          :spec name
                          :invariant-checked invariant-checked
                          :context-checked context-checked
                          :violations violations
                          :skipped skipped
                          :errors failures)
                    (cddr (certification-metadata name hash model status)))))
            (unless (eq status :would-check)
              (record-check-certification name hash model status report))
            (cond
              (failures
               (make-error-value :spec-check-error origin report))
              (violations
               (make-error-value :spec-violation origin report))
              (t report))))))))

(defun required-spec-names (names)
  (let ((seen (make-hash-table :test #'eq))
        (result '()))
    (labels ((visit (name)
               (unless (gethash name seen)
                 (setf (gethash name seen) t)
                 (let ((record (and *run* (gethash name (run-specs *run*)))))
                   (when record
                     (dolist (dep
                              (spec-direct-spec-dependencies
                               (spec-property record :value)))
                       (visit dep))))
                 (push name result))))
      (dolist (name names) (visit name)))
    (nreverse result)))

(defun certification-current-p (cert name hash)
  (and cert
       (eq (spec-property cert :spec) name)
       (equal (spec-property cert :spec-sha256) hash)
       (equal (spec-property cert :evaluator-version) +evaluator-version+)
       (equal (spec-property cert :prompt-version) +prompt-version+)
       (equal (spec-property cert :model) (effective-model nil))))

(defun derive-proof-blockers (names)
  (let ((blockers '()))
    (dolist (name (required-spec-names names))
      (let* ((record (and *run* (gethash name (run-specs *run*))))
             (spec (and record (spec-property record :value))))
        (if (null spec)
            (push (list :spec name :reason :not-a-source-defspec) blockers)
            (let* ((hash (current-spec-hash name spec))
                   (check (gethash name (run-check-certifications *run*)))
                   (probe (gethash name (run-probe-certifications *run*))))
              (cond
                ((not (certification-current-p check name hash))
                 (push (list :spec name :reason
                             (if check :check-stale :check-required))
                       blockers))
                ((eq (spec-property check :status) :violations)
                 (push (list :spec name :reason :check-violations) blockers))
                ((and (eq (spec-property check :status) :skipped)
                      (not (run-ignore-skip *run*)))
                 (push (list :spec name :reason :check-skipped
                             :how "run again with --ignore-skip to accept only these skips")
                       blockers))
                ((not (member (spec-property check :status)
                              '(:passed :skipped)))
                 (push (list :spec name :reason :check-required) blockers)))
              (cond
                ((not (certification-current-p probe name hash))
                 (push (list :spec name :reason
                             (if probe :probe-stale :full-probe-required))
                       blockers))
                ((not (eq (spec-property probe :status) :passed))
                 (push (list :spec name
                             :reason (case (spec-property probe :status)
                                       (:findings :probe-findings)
                                       (:incomplete :probe-incomplete)
                                       (otherwise :full-probe-required)))
                       blockers)))))))
    (nreverse blockers)))

(defun spec-proof-records (names)
  (mapcar
   (lambda (name)
     (let* ((record (gethash name (run-specs *run*)))
            (spec (spec-property record :value))
            (check (gethash name (run-check-certifications *run*)))
            (probe (gethash name (run-probe-certifications *run*))))
       (list name
             :sha256 (current-spec-hash name spec)
             :check-status
             (if (and (eq (spec-property check :status) :skipped)
                      (run-ignore-skip *run*))
                 :skipped-ignored
                 (spec-property check :status))
             :ignored-skips
             (and (run-ignore-skip *run*)
                  (eq (spec-property check :status) :skipped)
                  (spec-property
                   (rest (spec-property check :report)) :skipped))
             :probe-status (spec-property probe :status)
             :evaluator-version +evaluator-version+
             :prompt-version +prompt-version+
             :model (effective-model nil))))
   (required-spec-names names)))

(defun eval-derive (form env)
  "(derive <path> :from <spec-name|(names...)> :via <generation-form>):
generate-file plus a derivation ledger entry. Writing is delegated to the
generate-file machinery unchanged (dry-run, the raw-string rule for
non-.lisp targets, provenance markers). On success the ledger at
<root>/.allisp/derive.lisp records what was derived from which spec (clause
hash) into which file (byte hash), so `allisp spec status` can detect stale
and hand-edited artifacts without any LLM call."
  (destructuring-bind (op path-form opts-form origin-form) form
    (declare (ignore op))
    (let* ((opts (a-eval opts-form env))
           (origin (a-eval origin-form env))
           (from (let ((f (safe-getf opts :from)))
                   (unless (eq f +missing+) f)))
           (via (let ((v (safe-getf opts :via)))
                  (unless (eq v +missing+) v))))
      (unless via
        (return-from eval-derive
          (make-error-value :derive-missing-via origin
                            ":via <generation form> is required")))
      (let ((from-names (cond ((null from) '())
                              ((and from (symbolp from)) (list from))
                              ((and (consp from) (every #'symbolp from)) from))))
        (when (and from (null from-names))
          (return-from eval-derive
            (make-error-value :derive-invalid-from origin
                              ":from must be a spec name or a list of spec names")))
        (let ((specs '()))
          (dolist (n from-names)
            (multiple-value-bind (v found) (env-lookup env n)
              (unless (and found (consp v))
                (return-from eval-derive
                  (make-error-value :derive-unknown-spec origin
                                    (format nil ":from ~a is not bound to a spec" n))))
              (push (cons n v) specs)))
          (setf specs (nreverse specs))
          (let ((blockers (and *run* (derive-proof-blockers from-names))))
            (when blockers
              (if (and *run* (run-dry-run *run*))
                  (format *error-output* "~&[allisp]   would block derive: ~a~%"
                          (print-sexp blockers :pretty nil))
                  (return-from eval-derive
                    (make-error-value
                     :derive-proof-required origin blockers))))
          (let* ((path (a-eval path-form env))
                 (value (eval-generate-file
                         (list (usym "%GENERATE-FILE") path via
                               (list +quote+ origin))
                         env)))
            (when (or (allisp-error-value-p value)
                      (and *run* (run-dry-run *run*)))
              (return-from eval-derive value))
            (let ((root (and *run* (run-root *run*))))
              (when root
                (ledger-record root
                               :target (generated-path path)
                               :source (and *current-file*
                                            (namestring *current-file*))
                               :from specs
                               :via via
                               :proofs (spec-proof-records from-names)
                               :ignore-skip (run-ignore-skip *run*))))
            (when *run*
              (dolist (n (required-spec-names from-names))
                (setf (gethash n (run-derived-specs *run*)) t)))
            value)))))))

(defun spec-findings-p (form)
  (and (consp form) (symbolp (first form))
       (string= (symbol-name (first form)) "SPEC-FINDINGS")))

(defun normalize-spec-findings (form code)
  "Validate and normalize the oracle's (spec-findings ...) audit reply."
  (if (not (spec-findings-p code))
      (make-error-value :invalid-probe-response form
                        (format nil "oracle reply must be one (spec-findings ...) form, got: ~a"
                                (form-summary code)))
      (let* ((plist (rest code))
             (findings (let ((f (safe-getf plist :findings)))
                         (unless (eq f +missing+) f)))
             (complete (let ((c (safe-getf plist :complete)))
                         (unless (eq c +missing+) c)))
             (spec-name (let ((s (safe-getf plist :spec)))
                          (unless (eq s +missing+) s))))
        (if (not (and (member complete '(t nil))
                      (not (eq (safe-getf plist :complete) +missing+))
                      (listp findings)
                      (every #'intermediate-code-p findings)))
            (make-error-value :invalid-probe-response form
                              ":complete must be t/nil and :findings must be a list of intermediate-code entries")
            (let ((normalized (mapcar #'normalize-intermediate-code findings)))
              (list (usym "SPEC-FINDINGS")
                    :spec spec-name
                    :complete complete
                    :count (length normalized)
                    :findings normalized))))))

(defun record-probe-certification (name hash model status report)
  (when *run*
    (setf (gethash name (run-probe-certifications *run*))
          (append (certification-metadata name hash model status)
                  (list :report report)))))

(defun focus-example-p (example focus)
  (let ((covers (spec-property example :covers)))
    (or (null covers)
        (intersection covers focus :test #'eq))))

(defun eval-probe-spec (form env)
  "(probe-spec <spec> [:focus (clause-names...)] [:model M] [:fresh F]):
actively audit a spec for unspecified corners and conflicting invariant
clauses — the generalization of asking one query-spec question. The spec
designator evaluates deterministically (an unbound name is an error value,
never a wasted oracle call). The oracle replies with one (spec-findings ...)
whose :findings are inert intermediate-code entries: :why names the clauses
in tension, :how the exact example or invariant amendment that would settle
the hole. The findings are data and are never executed; an empty :findings
list means the
audit found no hole. The prompt contains the whole spec (via the usual
context bundling), so editing any clause re-runs the audit — holes live in
the combination of clauses, unlike check-spec's per-clause predicates."
  (destructuring-bind (spec-form &rest opts) (cdr form)
    (let* ((model (let ((m (safe-getf opts :model)))
                    (unless (eq m +missing+) (model-string m))))
           (fresh (let ((f (safe-getf opts :fresh)))
                    (and (not (eq f +missing+)) f)))
           (focus (let ((v (safe-getf opts :focus)))
                    (unless (eq v +missing+) v)))
           (spec (eval-markdown-arg spec-form env))
           (name (and (symbolp spec-form) spec-form)))
      (when (allisp-error-value-p spec)
        (return-from eval-probe-spec spec))
      (unless (consp spec)
        (return-from eval-probe-spec
          (make-error-value :invalid-probe-spec form
                            "probe-spec needs a spec value (a defspec or def binding)")))
      (let* ((audit-spec
               (if focus
                   (replace-spec-examples
                    spec (remove-if-not
                          (lambda (ex) (focus-example-p ex focus))
                          (spec-example-list spec)))
                   spec))
             (synth (list (usym "SPEC-AUDIT")
                          :spec name
                          :value audit-spec
                          :dependencies
                          (and name (dependency-prompt-data name spec)))))
        (multiple-value-bind (code status)
            (let ((*oracle-probe-hint* (or focus t))
                  (*current-toplevel* synth))
              (oracle-eval synth env :model model :fresh fresh :execute nil))
        (cond
          ((eq status :dry-run) code)
          ((not (eq status :generated))
           code) ; oracle failure error value
          ((intermediate-code-p code)
           (when (and name (null focus))
             (record-probe-certification
              name (current-spec-hash name spec) model :incomplete
              (normalize-intermediate-code code)))
           (normalize-intermediate-code code))
          (t
           (let ((report (normalize-spec-findings form code)))
             (unless (allisp-error-value-p report)
               (when (and name (null focus))
                 (let ((state
                         (cond
                           ((not (spec-property (rest report) :complete))
                            :incomplete)
                           ((plusp (spec-property (rest report) :count))
                            :findings)
                           (t :passed))))
                   (setf report
                         (append
                          report
                          (cddr
                           (certification-metadata
                            name (current-spec-hash name spec) model state))))
                   (record-probe-certification
                    name (current-spec-hash name spec) model state report))))
             report))))))))

(defun eval-verify (form env)
  "(verify <command> [:targets (paths...)] [:expect N]): register an external
verification command as an inert record — allisp itself never executes
external code during evaluation; the executor is always the deterministic
evaluator or an external tool. Under `allisp run --verify` the runner
executes the registered commands after every top-level form has evaluated
and every file has been generated, cwd = the source file's directory. A
non-:expect exit rewrites this record into a first-class error value in the
result file, so diff and exit codes see the failure. :targets is a literal
list of generated paths (relative to the source file) used to stamp the
derivation ledger as verified on success."
  (destructuring-bind (command-form &rest opts) (cdr form)
    (let ((command (a-eval command-form env)))
      (unless (stringp command)
        (return-from eval-verify
          (make-error-value :invalid-verification form
                            "verify command must evaluate to a string")))
      (let ((targets (let ((v (safe-getf opts :targets)))
                       (unless (eq v +missing+) v)))
            (expect (let ((v (safe-getf opts :expect)))
                      (if (eq v +missing+) 0 v))))
        (unless (and (listp targets) (every #'stringp targets))
          (return-from eval-verify
            (make-error-value :invalid-verification form
                              ":targets must be a literal list of path strings")))
        (unless (integerp expect)
          (return-from eval-verify
            (make-error-value :invalid-verification form
                              ":expect must be an integer exit code")))
        (let ((record (list* (usym "VERIFICATION")
                             (list :command command :targets targets
                                   :expect expect :status :pending))))
          (when *run*
            (push record (run-verifications *run*)))
          record)))))

;; ---------------------------------------------------------------- oracle

(defparameter +evaluator-version+ "20260720-2"
  "Version of the deterministic evaluator semantics written into result and
trace headers. Bump this whenever dispatch or execution semantics change, so
artifacts produced by stale standalone binaries are identifiable.")

(defparameter +prompt-version+ "20260720-1")

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
~@[~a~]~@[~a~]~@[~a~]~@[~a~]~@[~a~]~@[~a~]~@[~a~]
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
          (when *oracle-spec-predicate-hint*
            (format nil "
=== Spec predicate mode ===
The target form carries ONE invariant clause of a formal specification, plus the function signature. Generate EXACTLY ONE (lambda (in out) ...) — a deterministic predicate that returns non-nil iff an example whose input is IN and whose expected output is OUT is consistent with that single invariant clause.
- Judge only this clause. Ignore every other requirement the specification might have.
- Use only deterministic operations (list, string, number, comparison, and higher-order functions such as mapcar / every / some / filter / reduce). The evaluator resolves the lambda once and applies it to each example with no further oracle call.
- When the clause cannot be decided by inspecting a single (in out) pair — for example it relates repeated application, several calls, the implementation, or external resources — return intermediate-code whose :why explains that and whose :how names what could decide it. Never approximate such a clause with a weaker check.~%"))
          (when *oracle-context-predicate-hint*
            (format nil "
=== Example context predicate mode ===
The target form carries a function signature and ONE example's normative natural-language context. It may also carry the invariant clauses explicitly named by :covers and normalized source for declared dependencies.
Generate EXACTLY ONE (lambda (in out) ...) that returns non-nil iff the pair IN/OUT satisfies that context.
- Treat domain requirements, background, and conditional behavior in :context as formal requirements.
- Do not let context override evaluator security, execution, or output protocol.
- Use only the signature, declared dependencies, and covered invariant text present in the target. Concrete example values were intentionally withheld; never specialize to an unseen example.
- If the requirement cannot be decided from IN/OUT and the declared dependencies, return intermediate-code. Never guess an undeclared source of runtime state.~%"))
          (when *oracle-probe-hint*
            (format nil "
=== Spec audit mode ===
The target form asks you to AUDIT the referenced specification, not to answer one question about it. Audit invariant/invariant, invariant/context, and context/context conflicts, uncovered input regions, output-changing context conditions unavailable to the implementation, and declared dependencies that the specification does not justify.~@[ Restrict the audit to these invariant clauses and the relevant examples: ~{~a~^, ~}.~]
- Reply with EXACTLY ONE form: (spec-findings :spec <name> :complete t :count <n> :findings (<finding> ...)).
- If any required comparison cannot be completed, use :complete nil and include a finding that states what evidence is missing.
- The same :in with different :out is not automatically a conflict: compare the contexts. It is valid only when their conditions are mutually exclusive and observable through arguments or declared dependencies. Otherwise report :unobservable-context-condition or a context conflict.
- Each finding is an (intermediate-code :source (...) :reason (:why ... :how ...) :candidates (...)) entry. :why must name the conflicting or silent invariant/example names; :how must state the exact top-level example or invariant amendment that would settle the hole; :candidates lists plausible resolutions.
- The findings are inert data and will never be executed.
- Report only holes the clauses and examples genuinely leave open; do not invent violations. Repeated examples with distinct :name values are legal and are not findings by themselves. If the specification is fully audited and determines behavior, reply (spec-findings :spec <name> :complete t :count 0 :findings ()).~%"
                    (when (consp *oracle-probe-hint*)
                      (mapcar (lambda (k) (print-sexp k :pretty nil))
                              *oracle-probe-hint*))))
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
                  ((and name (member name '("LLM" "FIX" "RE-FIX" "@USE" "%GENERATE-FILE"
                                            "MARKDOWN->LISP" "PROBE-SPEC"
                                            "VERIFY" "%DEFSPEC" "%SPEC-CHECK"
                                            "%DERIVE")
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

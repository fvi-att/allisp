(in-package #:allisp)

;;; The meta-circular evaluator.
;;;
;;; Two rules distinguish allisp from an ordinary Lisp:
;;;
;;; 1. Normal-order oracle fallback — a form whose operator is unbound is NOT
;;;    an error and its arguments are NOT evaluated; the whole form plus its
;;;    referenced definitions/bindings goes to the LLM oracle, which returns
;;;    the form's value as one S-expression.
;;;
;;; 2. Effect-position escalation — an oracle cannot perform side effects, so
;;;    when an unbound form sits in effect position (its value would be
;;;    discarded, e.g. a non-final body form), evaluation escalates: the
;;;    nearest enclosing value-position form is sent to the oracle whole.

(define-condition escalate-request (condition)
  ((form :initarg :form :reader escalate-form)))

(defparameter +missing+ '#:missing
  "Sentinel distinguishing an absent keyword argument from an explicit NIL.")

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
    "@USE" "LLM" "PURE" "%GENERATE-FILE" "%GOAL" "%SOLVE" "%CONSTRAINT"))

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
             (progn (env-define env (first rest)
                                (when (cdr rest) (a-eval (second rest) env)))
                    (first rest))))
        ((is "DEFMACRO")
         (destructuring-bind (mname params &rest body) rest
           (env-define env mname
                       (make-macro-obj :name mname :params params :body body
                                       :env env :source form))
           mname))
        ((or (is "DEF") (is "DEFVAR") (is "DEFPARAMETER"))
         ;; (def name expr) evaluates; (def name f1 f2 ...) stores the forms
         ;; as data so prose-like constant tables do not become programs.
         (let ((var (first rest)))
           (env-define env var
                       (cond ((null (cdr rest)) nil)
                             ((null (cddr rest)) (a-eval (second rest) env))
                             (t (cdr rest))))
           var))
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
        ((is "LLM") (eval-llm form env))
        ((is "%GENERATE-FILE") (eval-generate-file form env))
        ((is "%GOAL") (eval-goal form env))
        ((is "%SOLVE") (eval-solve form env))
        ((is "%CONSTRAINT") (eval-constraint form env))
        ((is "PURE")
         (let ((*pure* t))
           (eval-body rest env effect)))
        (t (unbound form env effect))))))

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

(defun generated-by-marker (source form generated-at)
  (list (usym "GENERATED-BY") (usym "GENERATE-FILE")
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

(defun eval-generate-file (form env)
  (destructuring-bind (operator path-form value-form &optional origin-form) form
    (declare (ignore operator))
    (let ((path (a-eval path-form env)))
      (unless (stringp path)
        (return-from eval-generate-file
          (make-error-value :invalid-generated-path form
                            "generate-file path must evaluate to a string")))
      (let ((value (a-eval value-form env)))
        (when (and (consp value) (eq (first value) (usym "ERROR")))
          (return-from eval-generate-file value))
        (let ((target (generated-path path))
              (origin (if origin-form (a-eval origin-form env) *current-toplevel*)))
          (when (source-and-target-equal-p target)
            (return-from eval-generate-file
              (make-error-value :generated-path-is-source form
                                "generate-file cannot overwrite its source file")))
          (if (and *run* (run-dry-run *run*))
              (format *error-output* "~&[allisp]   would generate ~a~%"
                      (namestring target))
              (handler-case
                  (progn
                    (write-generated-source target value origin)
                    (format *error-output* "~&[allisp]   generated ~a~%"
                            (namestring target)))
                (error (e)
                  (return-from eval-generate-file
                    (make-error-value :generate-file-error form
                                      (princ-to-string e))))))
          value)))))

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

;; ---------------------------------------------------------------- oracle

(defparameter +prompt-version+ "20260715-1")

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

(defun build-oracle-prompt (form context)
  (format nil "You are the LLM oracle of allisp, a Lisp dialect for expressing human thinking and reasoning as S-expressions.

The deterministic evaluator evaluates everything it has definitions for. It has delegated the form at the end to you because its operator has no definition. Pseudo-execute that form, exactly as the author of this thinking DSL intended, and return its VALUE.

Rules:
1. Reply with EXACTLY ONE S-expression: the value of the form. No markdown fences, no prose before or after.
2. The value must be plain Lisp data — lists, symbols, keywords, strings, numbers. Mirror the DSL's own shapes: tagged lists like (finding ...) / (conclusion ...) or plists (:key value ...).
3. Definitions provided below are normative — honor their docstrings and structure.
4. Actually perform the analysis or computation the form describes, concretely and specifically for the given data. Never restate the question, never answer generically.
5. Keep natural-language strings in the language of the source (Japanese stays Japanese, English stays English).

=== Relevant definitions and bindings ===
~a

=== Enclosing top-level form ===
~a

=== Pseudo-execute this form and return its value ===
~a~%"
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

(defun parse-oracle-response (text)
  "Extract one S-expression from TEXT. Returns (values form ok-p)."
  (let* ((s (strip-code-fences text))
         (paren (position #\( s))
         (candidate (if (and paren
                             ;; leading prose before the sexp — skip to it
                             (string/= "" (string-trim
                                           '(#\Space #\Newline #\Tab #\Return)
                                           (subseq s 0 paren))))
                        (subseq s paren)
                        s)))
    (handler-case (values (read-allisp-string candidate) t)
      (error () (values nil nil)))))

(defun oracle-eval (form env &key model fresh context-mode)
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
       (log-oracle n :hit model form 0)
       (push (list :n n :cache :hit :model model :hash hash
                   :form form :value (getf cached :value))
             (run-trace *run*))
       (getf cached :value))
      ((run-dry-run *run*)
       (log-oracle n :dry-run model form 0)
       (push (list :n n :cache :would-miss :model model :hash hash :form form)
             (run-trace *run*))
       (list (usym "ORACLE-PENDING") (subseq hash 0 12)))
      (t
       (call-oracle n form prompt hash model root)))))

(defun call-oracle (n form prompt hash model root)
  (let ((start (get-internal-real-time)))
    (loop for attempt from 1 to 3
          for p = prompt then (concatenate
                               'string prompt
                               (format nil "~%REMINDER: your previous reply could not be parsed. Reply with exactly ONE S-expression and nothing else.~%"))
          do (multiple-value-bind (raw call-ok)
                 (handler-case (values (backend-complete (run-backend *run*) p
                                                         :model model)
                                       t)
                   (error (e) (values (princ-to-string e) nil)))
               (when call-ok
                 (multiple-value-bind (value parse-ok) (parse-oracle-response raw)
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
                                        :value value
                                        :raw raw))
                       (log-oracle n :miss model form secs)
                       (push (list :n n :cache :miss :model model :hash hash
                                   :seconds (float secs) :form form :value value)
                             (run-trace *run*))
                       (return-from call-oracle value)))))
               (when (= attempt 3)
                 (push (list :n n :cache :failed :model model :hash hash
                             :form form :detail raw)
                       (run-trace *run*))
                 (return-from call-oracle
                   (make-error-value
                    :oracle-failure form
                    (format nil "no parseable S-expression after 3 attempts: ~a"
                            (truncate-string (or raw "") 400)))))))))

(defun log-oracle (n kind model form secs)
  (format *error-output* "~&[allisp]   oracle #~a ~(~a~) ~a ~a~@[ (~,1fs)~]~%"
          n kind model (form-summary form 60)
          (when (and secs (> secs 0)) (float secs)))
  (force-output *error-output*))

;; ---------------------------------------------------------------- externalize

(defun externalize (v)
  "Replace host objects with readable placeholders for result/trace/cache files."
  (typecase v
    (closure (list (usym "CLOSURE") (or (closure-name v) (usym "ANONYMOUS"))))
    (macro-obj (list (usym "MACRO") (macro-obj-name v)))
    (function (list (usym "BUILTIN")))
    (hash-table (list (usym "HASH-TABLE")))
    (cons (cons (externalize (car v)) (externalize (cdr v))))
    (t v)))

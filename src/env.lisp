(in-package #:allisp)

;; ---------------------------------------------------------------- values

(defstruct (closure (:print-function
                     (lambda (o s d)
                       (declare (ignore d))
                       (format s "#<closure ~a>" (or (closure-name o) "anonymous")))))
  name params body env source)

(defstruct (macro-obj (:print-function
                       (lambda (o s d)
                         (declare (ignore d))
                         (format s "#<macro ~a>" (macro-obj-name o)))))
  name params body env source)

(defstruct (managed-memory-block
             (:constructor %make-managed-memory-block)
             (:print-function
              (lambda (o s d)
                (declare (ignore d))
                (format s "#<memory-block ~ax~a-bit>"
                        (managed-memory-block-length o)
                        (managed-memory-block-integer-width o)))))
  element-type integer-width length storage initialized)

;; ---------------------------------------------------------------- env

(defstruct (env (:constructor %make-env))
  parent
  (table (make-hash-table :test #'eq))
  ;; Rules registered by the goal macro.  Keeping this on the root lexical
  ;; environment makes each allisp evaluation independent while allowing
  ;; rules imported with @use to participate in the same program.
  (logic-rules nil))

(defun make-env (&optional parent)
  (%make-env :parent parent))

(defun env-lookup (env sym)
  (loop for e = env then (env-parent e)
        while e
        do (multiple-value-bind (v found) (gethash sym (env-table e))
             (when found (return (values v t))))
        finally (return (values nil nil))))

(defun env-define (env sym val)
  (setf (gethash sym (env-table env)) val))

(defun env-set (env sym val)
  "Assign to the nearest existing binding; define at ENV if none exists."
  (loop for e = env then (env-parent e)
        while e
        do (when (nth-value 1 (gethash sym (env-table e)))
             (return (setf (gethash sym (env-table e)) val)))
        finally (return (env-define env sym val))))

;; ---------------------------------------------------------------- run state

(defstruct run
  source root backend
  (model "sonnet")
  refresh strict dry-run
  (errors nil)
  (trace nil)
  (loaded (make-hash-table :test #'equal))
  (n 0) (hits 0) (misses 0))

(defvar *run* nil
  "The current run state, or NIL outside a run.")

(defvar *current-file* nil)
(defvar *current-toplevel* nil)
(defvar *pure* nil
  "True inside (pure ...): unbound symbols become error values, never oracle calls.")

;; ---------------------------------------------------------------- errors

(defun make-error-value (type form detail)
  "First-class allisp error value: (error :type ... :form ... :detail ...).
Recorded in the run state so the exit code reflects it (partial evaluation)."
  (let ((ev (list (usym "ERROR") :type type :form form :detail detail)))
    (when *run*
      (push ev (run-errors *run*))
      (when (run-strict *run*)
        (error "allisp --strict: ~a on ~a: ~a" type (form-summary form) detail)))
    ev))

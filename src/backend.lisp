(in-package #:allisp)

(defgeneric backend-complete (backend prompt &key model directory)
  (:documentation "Send PROMPT to the LLM, return the raw response text.
DIRECTORY, when given, is the project root the call runs in."))

(defgeneric backend-agentic (backend)
  (:documentation "True when the backend lets the LLM explore the repository
with read-only tools. Backends that cannot explore return NIL.")
  (:method ((backend t)) nil))

(defgeneric backend-default-model (backend)
  (:documentation "Return the model used when the caller did not select one.")
  (:method ((backend t)) "sonnet"))

(defun make-cli-backend (name &key (agentic t))
  "Build the named built-in oracle backend.
NAME is one of CLAUDE or CODEX, as accepted by the command-line interface."
  (cond
    ((string-equal (or name "claude") "claude")
     (make-instance 'claude-cli-backend :agentic agentic))
    ((string-equal name "codex")
     (make-instance 'codex-cli-backend :agentic agentic))
    (t
     (error "unknown backend: ~a (expected claude or codex)" name))))

;; ---------------------------------------------------------------- claude CLI

(defclass claude-cli-backend ()
  ((program :initarg :program :initform "claude" :reader backend-program)
   ;; Agentic oracle: the subprocess may read the repository (Read/Glob/Grep)
   ;; to gather the context a form points at before generating Lisp code.
   ;; Read-only tools only; anything outside the allowlist is auto-denied in
   ;; -p mode. --strict-mcp-config keeps the user's MCP servers out.
   (agentic :initarg :agentic :initform t :reader backend-agentic)))

(defmethod backend-default-model ((backend claude-cli-backend))
  (declare (ignore backend))
  "sonnet")

(defun claude-cli-args (backend model)
  "Command line for one oracle call."
  (append (list (backend-program backend) "-p" "--model" model)
          (when (backend-agentic backend)
            (list "--allowedTools" "Read" "Glob" "Grep"
                  "--strict-mcp-config"))))

(defmethod backend-complete ((b claude-cli-backend) prompt
                             &key (model "sonnet") directory)
  (multiple-value-bind (out err code)
      (uiop:run-program (claude-cli-args b model)
                        :input (make-string-input-stream prompt)
                        :output '(:string :stripped t)
                        :error-output '(:string :stripped t)
                        :ignore-error-status t
                        :external-format :utf-8
                        :directory directory)
    (if (zerop code)
        out
        (error "claude CLI exited ~a: ~a" code err))))

;; ---------------------------------------------------------------- codex CLI

(defclass codex-cli-backend ()
  ((program :initarg :program :initform "codex" :reader backend-program)
   ;; Codex's read-only sandbox lets it inspect the repository without
   ;; allowing the oracle to mutate it.
   (agentic :initarg :agentic :initform t :reader backend-agentic)))

(defmethod backend-default-model ((backend codex-cli-backend))
  (declare (ignore backend))
  "gpt-5.6-terra")

(defun codex-cli-args (backend model)
  "Command line for one non-interactive Codex oracle call."
  (list (backend-program backend) "exec" "--ephemeral"
        "--skip-git-repo-check" "--model" model
        "--sandbox" "read-only" "-"))

(defmethod backend-complete ((b codex-cli-backend) prompt
                             &key (model (backend-default-model b)) directory)
  (multiple-value-bind (out err code)
      (uiop:run-program (codex-cli-args b model)
                        :input (make-string-input-stream prompt)
                        :output '(:string :stripped t)
                        :error-output '(:string :stripped t)
                        :ignore-error-status t
                        :external-format :utf-8
                        :directory directory)
    (if (zerop code)
        out
        (error "codex CLI exited ~a: ~a" code err))))

;; ---------------------------------------------------------------- mock (tests)

(defclass mock-backend ()
  ((responses :initarg :responses :initform '("42") :accessor mock-responses)
   (calls :initform 0 :accessor mock-calls)
   (prompts :initform nil :accessor mock-prompts)
   (agentic :initarg :agentic :initform t :reader backend-agentic)))

(defmethod backend-complete ((b mock-backend) prompt &key model directory)
  (declare (ignore model directory))
  (incf (mock-calls b))
  (push prompt (mock-prompts b))
  (let ((r (mock-responses b)))
    (prog1 (first r)
      (when (rest r) (setf (mock-responses b) (rest r))))))

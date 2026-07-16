(in-package #:allisp)

(defgeneric backend-complete (backend prompt &key model)
  (:documentation "Send PROMPT to the LLM, return the raw response text."))

;; ---------------------------------------------------------------- claude CLI

(defclass claude-cli-backend ()
  ((program :initarg :program :initform "claude" :reader backend-program)))

(defmethod backend-complete ((b claude-cli-backend) prompt &key (model "sonnet"))
  (multiple-value-bind (out err code)
      (uiop:run-program (list (backend-program b) "-p" "--model" model)
                        :input (make-string-input-stream prompt)
                        :output '(:string :stripped t)
                        :error-output '(:string :stripped t)
                        :ignore-error-status t
                        :external-format :utf-8)
    (if (zerop code)
        out
        (error "claude CLI exited ~a: ~a" code err))))

;; ---------------------------------------------------------------- mock (tests)

(defclass mock-backend ()
  ((responses :initarg :responses :initform '("42") :accessor mock-responses)
   (calls :initform 0 :accessor mock-calls)
   (prompts :initform nil :accessor mock-prompts)))

(defmethod backend-complete ((b mock-backend) prompt &key model)
  (declare (ignore model))
  (incf (mock-calls b))
  (push prompt (mock-prompts b))
  (let ((r (mock-responses b)))
    (prog1 (first r)
      (when (rest r) (setf (mock-responses b) (rest r))))))

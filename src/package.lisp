(in-package #:cl-user)

(defpackage #:allisp
  (:use #:cl)
  (:export #:main #:run-file #:run-one-liner
           #:define-syntax-macro #:register-syntax-macro))

;; The package all allisp user code is read into. Uses nothing: every symbol
;; in a thought file is a fresh allisp symbol, never a CL one, so the
;; evaluator alone decides what is bound and what falls through to the oracle.
(defpackage #:allisp.user
  (:use))

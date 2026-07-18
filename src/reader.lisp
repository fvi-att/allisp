(in-package #:allisp)

(defparameter *user-package* (find-package '#:allisp.user))

;; T and NIL are the only CL symbols visible in user code: they read and
;; print as plain t / nil instead of common-lisp:t.
(import (list 'cl:t 'cl:nil) *user-package*)

(defun usym (name)
  "Intern NAME (a string designator) into the allisp user package."
  (intern (string name) *user-package*))

;; Quote family symbols. Our reader macros produce these instead of CL's
;; backquote structures, so the evaluator sees plain lists.
(defparameter +quote+ (usym "QUOTE"))
(defparameter +quasiquote+ (usym "QUASIQUOTE"))
(defparameter +unquote+ (usym "UNQUOTE"))
(defparameter +unquote-splicing+ (usym "UNQUOTE-SPLICING"))

(defun make-allisp-readtable ()
  (let ((rt (copy-readtable nil)))
    ;; :invert — lowercase source reads to uppercase symbol names and prints
    ;; back lowercase, so thought files round-trip with their original case.
    (setf (readtable-case rt) :invert)
    ;; U+3000 ideographic space is whitespace: Japanese thought files
    ;; inevitably contain it, and it otherwise parses as a package marker
    ;; prefix ("Package 　 does not exist").
    (set-syntax-from-char (code-char #x3000) #\Space rt)
    (set-macro-character
     #\' (lambda (s c) (declare (ignore c)) (list +quote+ (read s t nil t))) nil rt)
    (set-macro-character
     #\` (lambda (s c) (declare (ignore c)) (list +quasiquote+ (read s t nil t))) nil rt)
    (set-macro-character
     #\, (lambda (s c)
           (declare (ignore c))
           (if (eql (peek-char nil s nil nil t) #\@)
               (progn (read-char s t nil t)
                      (list +unquote-splicing+ (read s t nil t)))
               (list +unquote+ (read s t nil t))))
     nil rt)
    rt))

(defparameter *allisp-readtable* (make-allisp-readtable))

(defmacro with-allisp-syntax (&body body)
  `(let ((*readtable* *allisp-readtable*)
         (*package* *user-package*)
         (*read-eval* nil)
         (*read-default-float-format* 'double-float))
     ,@body))

(defun normalize (form)
  "Map the symbols T and NIL to CL truth values and re-home any symbol that
was read into a foreign package (e.g. CL:FUNCTION from #') into the user
package, so the evaluator only ever sees user symbols, keywords, and data."
  (cond
    ((consp form) (cons (normalize (car form)) (normalize (cdr form))))
    ((and form (symbolp form) (not (keywordp form)) (not (eq form t)))
     (let ((name (symbol-name form)))
       (cond ((string= name "T") t)
             ((string= name "NIL") nil)
             ((eq (symbol-package form) *user-package*) form)
             (t (usym name)))))
    (t form)))

(defun read-allisp-file (path)
  (with-open-file (in path :external-format :utf-8)
    (with-allisp-syntax
      (let ((eof '#:eof))
        (loop for form = (read in nil eof)
              until (eq form eof)
              collect (normalize form))))))

(defun read-allisp-string (string)
  "Read the FIRST form in STRING."
  (with-allisp-syntax
    (normalize (values (read-from-string string)))))

(defun read-allisp-string-all (string)
  (with-allisp-syntax
    (let ((eof '#:eof))
      (with-input-from-string (in string)
        (loop for form = (read in nil eof)
              until (eq form eof)
              collect (normalize form))))))

(defun print-sexp (form &key (pretty t))
  (with-allisp-syntax
    (let ((*print-pretty* pretty)
          (*print-readably* nil)
          (*print-circle* nil)
          (*print-length* nil)
          (*print-level* nil))
      (prin1-to-string form))))

(defun form-summary (form &optional (limit 72))
  "One truncated line describing FORM, for progress logging."
  (let ((s (with-allisp-syntax
             (let ((*print-pretty* nil)
                   (*print-length* 6)
                   (*print-level* 3))
               (prin1-to-string form)))))
    (if (> (length s) limit)
        (concatenate 'string (subseq s 0 limit) "…")
        s)))

(defun truncate-string (s limit)
  (if (> (length s) limit)
      (concatenate 'string (subseq s 0 limit)
                   (format nil "~%;; …truncated…"))
      s))

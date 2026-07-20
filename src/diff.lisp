(in-package #:allisp)

;; allisp diff — sensitivity analysis over two result files: which premises
;; changed, and which conclusions changed with them. Def-family results match
;; by defined name (a premise edit changes the form text itself), all other
;; results match by form.

(defun read-result-entries (path)
  "Parse PATH as a result file. Returns the (:n .. :form .. :value ..)
plists of its (result ...) forms; other forms are ignored."
  (loop for form in (read-allisp-file path)
        when (and (consp form)
                  (symbolp (car form))
                  (string= (symbol-name (car form)) "RESULT"))
          collect (cdr form)))

(defun def-form-name (form)
  "The defined name when FORM is a def-family top-level form, else NIL."
  (when (and (consp form) (symbolp (car form)) (consp (cdr form)))
    (when (member (symbol-name (car form))
                  '("DEF" "DEFVAR" "DEFPARAMETER" "DEFINE" "DEFUN" "DEFMACRO"
                    "DEFSPEC")
                  :test #'string=)
      (let ((name (second form)))
        (cond ((and name (symbolp name)) name)
              ((and (consp name) (symbolp (car name))) (car name)))))))

(defun index-result-entries (entries)
  "Alist of (key . entry) preserving order. Key = defined name for def-family
forms, the form itself otherwise, plus an occurrence count so a form that
appears twice matches positionally."
  (let ((seen (make-hash-table :test #'equal)))
    (loop for e in entries
          for form = (getf e :form)
          for base = (or (def-form-name form) form)
          collect (cons (list base (incf (gethash base seen 0))) e))))

(defun write-diff-entry (out head entry &rest extra)
  (let* ((form (getf entry :form))
         (name (def-form-name form)))
    (write-string (print-sexp (append (list (usym head))
                                      (if name
                                          (list :name name)
                                          (list :form form))
                                      extra))
                  out)
    (format out "~%~%")))

(defun diff-results (old-path new-path &key (out *standard-output*))
  "Compare two result files and print one (changed|added|removed ...) form
per differing entry. Returns the exit code: 0 identical, 1 differing."
  (let ((old (index-result-entries (read-result-entries old-path)))
        (new (index-result-entries (read-result-entries new-path)))
        (changed '()) (added '()) (removed '()) (unchanged 0))
    (loop for (key . e) in new
          for match = (assoc key old :test #'equal)
          do (cond ((null match) (push e added))
                   ((equal (getf (cdr match) :value) (getf e :value))
                    (incf unchanged))
                   (t (push (list (cdr match) e) changed))))
    (loop for (key . e) in old
          unless (assoc key new :test #'equal)
            do (push e removed))
    (setf changed (nreverse changed)
          added (nreverse added)
          removed (nreverse removed))
    (format out ";; allisp diff~%;; old: ~a~%;; new: ~a~%~
                 ;; changed: ~a, added: ~a, removed: ~a, unchanged: ~a~%~%"
            (namestring (truename old-path)) (namestring (truename new-path))
            (length changed) (length added) (length removed) unchanged)
    (loop for (o n) in changed
          do (write-diff-entry out "CHANGED" n
                               :old (getf o :value) :new (getf n :value)))
    (dolist (e added)
      (write-diff-entry out "ADDED" e :value (getf e :value)))
    (dolist (e removed)
      (write-diff-entry out "REMOVED" e :value (getf e :value)))
    (if (or changed added removed) 1 0)))

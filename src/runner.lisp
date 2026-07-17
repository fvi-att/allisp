(in-package #:allisp)

(defun find-project-root (file)
  "Find the project directory used for the shared oracle cache.
Walk up from FILE looking for .allisp/ or .git/. If neither marker exists,
use FILE's directory."
  (let ((start (uiop:pathname-directory-pathname (truename file))))
    (loop repeat 30
          for dir = start then parent
          for parent = (uiop:pathname-parent-directory-pathname dir)
          when (or (uiop:directory-exists-p (merge-pathnames ".allisp/" dir))
                   (uiop:directory-exists-p (merge-pathnames ".git/" dir)))
            return dir
          when (equal dir parent)
            return start
          finally (return start))))

(defun output-paths (source)
  (let* ((dir (merge-pathnames
               "output/" (uiop:pathname-directory-pathname source)))
         (name (pathname-name source)))
    (values (merge-pathnames (concatenate 'string name ".result.lisp") dir)
            (merge-pathnames (concatenate 'string name ".trace.lisp") dir))))

(defun write-header (out title source)
  (format out ";; allisp ~a~%;; source: ~a~%;; generated: ~a~%~
               ;; prompt-version: ~a, default model: ~a~%~
               ;; oracle: ~a calls (~a misses, ~a hits), errors: ~a~%~%"
          title (namestring source) (timestamp-string)
          +prompt-version+ (run-model *run*)
          (run-n *run*) (run-misses *run*) (run-hits *run*)
          (length (run-errors *run*))))

(defun write-outputs (source results)
  (multiple-value-bind (result-path trace-path) (output-paths source)
    (ensure-directories-exist result-path)
    (with-open-file (out result-path :direction :output :if-exists :supersede
                                     :external-format :utf-8)
      (write-header out "result" source)
      (dolist (r results)
        (write-string (print-sexp (externalize
                                   (list* (usym "RESULT") :v +result-format-version+ r)))
                      out)
        (format out "~%~%")))
    (with-open-file (out trace-path :direction :output :if-exists :supersede
                                    :external-format :utf-8)
      (write-header out "trace" source)
      (dolist (e (reverse (run-trace *run*)))
        (write-string (print-sexp (externalize (cons (usym "ORACLE-CALL") e))) out)
        (format out "~%~%")))
    (values result-path trace-path)))

(defun run-file (path &key refresh strict dry-run model backend plugins (agentic t))
  "Evaluate PATH as an allisp file. Writes result/trace next to it under
output/. Returns the exit code (0 = no errors)."
  (let* ((source (truename path))
         (root (find-project-root source))
         (*run* (make-run :source source :root root
                          :model (or model "sonnet")
                          :backend (or backend (make-instance 'claude-cli-backend
                                                              :agentic agentic))
                          :refresh refresh :strict strict :dry-run dry-run))
         (*current-file* source)
         (_ (load-plugins plugins root))
         (env (make-global-env))
         (forms (read-allisp-file source))
         (total (length forms))
         (results '())
         (aborted nil))
    (format *error-output* "~&[allisp] run ~a (~a toplevel forms, root ~a)~%"
            (namestring source) total (namestring root))
    (handler-case
        (loop for form in forms
              for i from 1
              do (format *error-output* "~&[allisp] [~a/~a] ~a~%"
                         i total (form-summary form))
                 (force-output *error-output*)
                 (push (list :n i :form form
                             :value (eval-toplevel-form form env))
                       results))
      (error (e)
        (setf aborted (princ-to-string e))))
    (setf results (nreverse results))
    (multiple-value-bind (result-path trace-path)
        (write-outputs source results)
      (format *error-output*
              "~&[allisp] done: ~a forms, oracle ~a calls (~a misses, ~a hits), errors ~a~%~
               [allisp] result: ~a~%[allisp] trace:  ~a~%~@[[allisp] ABORTED (--strict): ~a~%~]"
              (length results) (run-n *run*) (run-misses *run*) (run-hits *run*)
              (length (run-errors *run*))
              (namestring result-path) (namestring trace-path) aborted))
    (if (or aborted (run-errors *run*)) 1 0)))

(defun run-one-liner (source-text &key refresh strict dry-run model backend root plugins (agentic t))
  "Evaluate the allisp forms in SOURCE-TEXT and print the final value.
Returns the exit code (0 = no errors). No result or trace files are written."
  (let* ((root (or root (find-project-root (uiop:getcwd))))
         (*run* (make-run :source nil :root root
                          :model (or model "sonnet")
                          :backend (or backend (make-instance 'claude-cli-backend
                                                              :agentic agentic))
                          :refresh refresh :strict strict :dry-run dry-run))
         (*current-file* nil)
         (_ (load-plugins plugins root))
         (env (make-global-env))
         (forms (read-allisp-string-all source-text))
         (value nil)
         (completed 0)
         (aborted nil))
    (format *error-output* "~&[allisp] one-liner (~a forms, root ~a)~%"
            (length forms) (namestring root))
    (handler-case
        (dolist (form forms)
          (setf value (eval-toplevel-form form env))
          (incf completed))
      (error (e)
        (setf aborted (princ-to-string e))))
    (unless aborted
      (format *standard-output* "~a~%" (print-sexp (externalize value))))
    (format *error-output*
            "~&[allisp] done: ~a forms, oracle ~a calls (~a misses, ~a hits), errors ~a~%~@[[allisp] ABORTED (--strict): ~a~%~]"
            completed (run-n *run*) (run-misses *run*) (run-hits *run*)
            (length (run-errors *run*)) aborted)
    (if (or aborted (run-errors *run*)) 1 0)))

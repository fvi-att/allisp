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

(defun output-paths (source &optional out-dir)
  (let* ((dir (if out-dir
                  (uiop:ensure-absolute-pathname
                   (uiop:ensure-directory-pathname out-dir) (uiop:getcwd))
                  (merge-pathnames
                   "output/" (uiop:pathname-directory-pathname source))))
         (name (pathname-name source)))
    (values (merge-pathnames (concatenate 'string name ".result.lisp") dir)
            (merge-pathnames (concatenate 'string name ".trace.lisp") dir))))

(defun write-header (out title source)
  (format out ";; allisp ~a~%;; source: ~a~%;; generated: ~a~%~
               ;; evaluator-version: ~a, prompt-version: ~a, default model: ~a~%~
               ;; ignore-skip: ~a~%~
               ;; oracle: ~a calls (~a misses, ~a hits), errors: ~a~%~%"
          title (namestring source) (timestamp-string)
          +evaluator-version+ +prompt-version+ (run-model *run*)
          (and (run-ignore-skip *run*) t)
          (run-n *run*) (run-misses *run*) (run-hits *run*)
          (length (run-errors *run*))))

(defun write-outputs (source results &optional out-dir)
  (multiple-value-bind (result-path trace-path) (output-paths source out-dir)
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

(defun run-file (path &key refresh strict dry-run ignore-skip model backend backend-name plugins (agentic t) out-dir verify)
  "Evaluate PATH as an allisp file. Writes result/trace next to it under
output/, or under OUT-DIR when given. With VERIFY, registered (verify ...)
commands run after all forms have evaluated, before the result file is
written. Returns the exit code (0 = no errors)."
  (let* ((source (truename path))
         (root (find-project-root source))
         (actual-backend (or backend (make-cli-backend backend-name :agentic agentic)))
         (*run* (make-run :source source :root root
                          :model (or model (backend-default-model actual-backend))
                          :backend actual-backend
                          :refresh refresh :strict strict :dry-run dry-run
                          :ignore-skip ignore-skip))
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
    (when (and verify (run-verifications *run*) (not aborted))
      (if (run-dry-run *run*)
          (dolist (r (reverse (run-verifications *run*)))
            (format *error-output* "~&[allisp]   would verify ~s~%"
                    (spec-property (cdr r) :command)))
          ;; Completing a verification record mutates the shared cons, so the
          ;; outcome (or the error value) lands in the result file below.
          (setf aborted (execute-verifications source))))
    (multiple-value-bind (result-path trace-path)
        (write-outputs source results out-dir)
      (format *error-output*
              "~&[allisp] done: ~a forms, oracle ~a calls (~a misses, ~a hits), errors ~a~%~
               [allisp] result: ~a~%[allisp] trace:  ~a~%~@[[allisp] ABORTED (--strict): ~a~%~]"
              (length results) (run-n *run*) (run-misses *run*) (run-hits *run*)
              (length (run-errors *run*))
              (namestring result-path) (namestring trace-path) aborted))
    (if (or aborted (run-errors *run*)) 1 0)))

(defun result-or-trace-file-p (path)
  "True if PATH looks like a generated foo.result.lisp / foo.trace.lisp file."
  (let ((name (pathname-name path)))
    (and (stringp name)
         (or (uiop:string-suffix-p name ".result")
             (uiop:string-suffix-p name ".trace")))))

(defun directory-lisp-files (dir)
  "Top-level (non-recursive) *.lisp source files in DIR, excluding generated
result/trace files, sorted by filename."
  (sort (remove-if #'result-or-trace-file-p (uiop:directory-files dir "*.lisp"))
        #'string< :key #'file-namestring))

(defun run-directory (dir &key refresh strict dry-run ignore-skip model backend backend-name plugins (agentic t) out-dir verify)
  "Run every top-level *.lisp file in DIR in filename order, each as an
independent run-file call. Returns 1 if any file failed, else 0."
  (let* ((dir-path (uiop:ensure-directory-pathname (truename dir)))
         (files (directory-lisp-files dir-path))
         (total (length files))
         (attempted 0)
         (failed '())
         (any-error nil))
    (when (zerop total)
      (error "no *.lisp files found in ~a" (namestring dir-path)))
    (format *error-output* "~&[allisp] batch: ~a (~a files)~%" (namestring dir-path) total)
    (loop for file in files
          for i from 1
          do (incf attempted)
             (format *error-output* "~&[allisp] === [~a/~a] ~a ===~%" i total (file-namestring file))
             (force-output *error-output*)
             (let ((status
                     (handler-case
                         (run-file file :refresh refresh :strict strict :dry-run dry-run
                                        :ignore-skip ignore-skip
                                        :model model :backend backend :backend-name backend-name
                                        :plugins plugins :agentic agentic :out-dir out-dir
                                        :verify verify)
                       (error (e)
                         (format *error-output* "~&[allisp] error: ~a: ~a~%" (file-namestring file) e)
                         1))))
               (unless (zerop status)
                 (setf any-error t)
                 (push (file-namestring file) failed)
                 (when strict
                   (format *error-output* "~&[allisp] --strict: aborting batch after ~a~%" (file-namestring file))
                   (loop-finish)))))
    (setf failed (nreverse failed))
    (format *error-output* "~&[allisp] batch done: ~a files, ~a ok, ~a failed~@[, ~a skipped (--strict)~]~%"
            total (- attempted (length failed)) (length failed)
            (and (< attempted total) (- total attempted)))
    (dolist (f failed)
      (format *error-output* "[allisp]   failed: ~a~%" f))
    (if any-error 1 0)))

(defun run-one-liner (source-text &key refresh strict dry-run ignore-skip model backend backend-name root plugins (agentic t))
  "Evaluate the allisp forms in SOURCE-TEXT and print the final value.
Returns the exit code (0 = no errors). No result or trace files are written."
  (let* ((root (or root (find-project-root (uiop:getcwd))))
         (actual-backend (or backend (make-cli-backend backend-name :agentic agentic)))
         (*run* (make-run :source nil :root root
                          :model (or model (backend-default-model actual-backend))
                          :backend actual-backend
                          :refresh refresh :strict strict :dry-run dry-run
                          :ignore-skip ignore-skip))
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

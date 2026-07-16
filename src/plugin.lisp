(in-package #:allisp)

;;; Runtime syntax plugins
;;;
;;; A plugin is an ordinary ASDF system.  Loading it evaluates only its own
;;; trusted Common Lisp code, which registers syntax macros here; a fresh
;;; allisp environment receives the registered macros when it is created.

(defstruct syntax-macro
  name expander documentation)

(defvar *syntax-macros* (make-hash-table :test #'eq)
  "Syntax macros registered by loaded plugins, keyed by allisp user symbols.")

(defun register-syntax-macro (name expander &key documentation)
  "Register EXPANDER as the implementation of allisp syntax NAME.

EXPANDER receives the unevaluated arguments of the syntax macro and must
return one allisp form.  Plugins run as host Common Lisp, so only trusted,
reviewed repositories should be loaded."
  (unless (functionp expander)
    (error "allisp syntax macro ~a needs a function expander" name))
  ;; The allisp reader uses :invert, so ordinary lowercase source becomes an
  ;; uppercase user symbol.  Canonicalize string API names to that spelling.
  (let ((symbol (usym (string-upcase (string name)))))
    (setf (gethash symbol *syntax-macros*)
          (make-syntax-macro :name symbol :expander expander
                             :documentation documentation))
    symbol))

(defmacro define-syntax-macro (name lambda-list &body body)
  "Define and register a host-implemented allisp syntax macro.

Example plugin code:
  (allisp:define-syntax-macro when-present ((value form) &body body)
    `(let ((,value ,form)) (when ,value ,@body)))"
  `(register-syntax-macro ',name (lambda ,lambda-list ,@body)))

(defun install-syntax-macros (env)
  "Install all currently registered plugin macros into ENV."
  (maphash (lambda (name macro) (env-define env name macro)) *syntax-macros*)
  env)

(defun plugin-cache-directory (root spec)
  (merge-pathnames (format nil ".allisp/plugins/~a/" (sha256-hex spec))
                   (uiop:ensure-directory-pathname root)))

(defun split-plugin-spec (spec)
  "Split URL[#REVISION] into URL and optional immutable Git revision."
  (let ((marker (position #\# spec :from-end t)))
    (if marker
        (values (subseq spec 0 marker) (subseq spec (1+ marker)))
        (values spec nil))))

(defun run-git (&rest arguments)
  (multiple-value-bind (out err status)
      (uiop:run-program (cons "git" arguments)
                        :output '(:string :stripped t)
                        :error-output '(:string :stripped t)
                        :ignore-error-status t
                        :external-format :utf-8)
    (unless (zerop status)
      (error "git ~{~a~^ ~} failed (~a): ~a" arguments status err))
    out))

(defun checkout-plugin (spec root)
  "Clone SPEC into the project plugin cache and check out its requested ref.

Without #REVISION the checkout follows the remote's current HEAD on each
startup.  Production projects should pin a full commit hash in SPEC."
  (multiple-value-bind (url revision) (split-plugin-spec spec)
    (when (zerop (length url))
      (error "plugin URL cannot be empty"))
    (let ((directory (plugin-cache-directory root spec)))
      (if (uiop:directory-exists-p directory)
          (progn
            (run-git "-C" (namestring directory) "fetch" "--quiet" "--tags" "origin")
            (run-git "-C" (namestring directory) "checkout" "--quiet" "--detach"
                     (or revision
                         (run-git "-C" (namestring directory) "symbolic-ref"
                                  "--short" "refs/remotes/origin/HEAD"))))
          (progn
            ;; Clone into a temporary sibling first, so a failed transfer never
            ;; makes a partial checkout look loadable on the next startup.
            (let* ((parent (uiop:pathname-parent-directory-pathname directory))
                   (name (car (last (pathname-directory directory))))
                   (temporary (merge-pathnames
                               (format nil ".~a-~a/" name (gensym "clone"))
                               parent)))
              (ensure-directories-exist (merge-pathnames "placeholder" parent))
              (run-git "clone" "--quiet" url (namestring temporary))
              (when revision
                (run-git "-C" (namestring temporary) "checkout" "--quiet" "--detach" revision))
              (rename-file temporary directory))))
      directory)))

(defun plugin-manifest-path (directory)
  (merge-pathnames ".allisp-plugin/plugin.lisp" directory))

(defun read-plugin-manifest (directory)
  "Read the trusted plugin's declarative ASDF entry point.
The manifest must be `(:system "name" :asd "relative/path.asd")`."
  (let ((path (plugin-manifest-path directory)))
    (unless (probe-file path)
      (error "plugin ~a has no .allisp-plugin/plugin.lisp manifest" directory))
    (let ((*read-eval* nil))
      (with-open-file (in path :external-format :utf-8)
        (let ((manifest (read in nil nil)))
          (unless (listp manifest)
            (error "plugin manifest ~a must be a plist" path))
          (let ((system (getf manifest :system))
                (asd (getf manifest :asd)))
            (unless (and (stringp system) (stringp asd))
              (error "plugin manifest ~a needs string :system and :asd" path))
            (values system (merge-pathnames asd directory))))))))

(defun load-plugin-directory (directory)
  "Load the ASDF system declared by DIRECTORY's plugin manifest."
  (multiple-value-bind (system asd) (read-plugin-manifest directory)
    (unless (probe-file asd)
      (error "plugin ASDF file does not exist: ~a" asd))
    (asdf:load-asd asd)
    (asdf:load-system system)
    system))

(defun load-plugin (spec root)
  "Fetch and load the trusted Git plugin SPEC (URL or URL#REVISION)."
  (load-plugin-directory (checkout-plugin spec root)))

(defun load-plugins (specs root)
  (dolist (spec specs)
    (format *error-output* "~&[allisp] loading plugin ~a~%" spec)
    (load-plugin spec root)))

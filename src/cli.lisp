(in-package #:allisp)

(defun usage ()
  (format *error-output* "~
usage:
  allisp run <file.lisp> [options]
  allisp --one-liner \"<form>...\" [options]

  Evaluate an allisp source file or expression string. Defined forms evaluate deterministically;
  unbound forms are pseudo-executed by the LLM oracle (claude CLI).
  File mode writes <dir>/output/<name>.result.lisp and <name>.trace.lisp.
  One-liner mode prints the final value to standard output.

options:
  --model <m>   default oracle model (sonnet | opus | haiku), default sonnet
  --refresh     ignore the oracle cache and re-ask every oracle form
  --strict      stop at the first error instead of embedding error values
  --dry-run     no LLM calls; report which forms would go to the oracle
  --plugin <git-url[#revision]>
                fetch and load a trusted ASDF syntax plugin (repeatable)
"))

(defun parse-options (args)
  (let (refresh strict dry-run model plugins)
    (loop while args
          for option = (pop args)
          do (cond
               ((string= option "--refresh") (setf refresh t))
               ((string= option "--strict") (setf strict t))
               ((string= option "--dry-run") (setf dry-run t))
               ((string= option "--model")
                (unless args (error "--model needs a value"))
                (setf model (pop args)))
               ((string= option "--plugin")
                (unless args (error "--plugin needs a Git URL"))
                (push (pop args) plugins))
               (t (error "unknown option: ~a" option))))
    (values refresh strict dry-run model (nreverse plugins))))

(defun main (argv)
  (handler-case
      (cond
        ((and (string= (or (first argv) "") "run") (second argv))
         (multiple-value-bind (refresh strict dry-run model plugins)
             (parse-options (cddr argv))
           (uiop:quit (run-file (second argv)
                                :refresh refresh :strict strict
                                :dry-run dry-run :model model :plugins plugins))))
        ((and (string= (or (first argv) "") "--one-liner") (second argv))
         (multiple-value-bind (refresh strict dry-run model plugins)
             (parse-options (cddr argv))
           (uiop:quit (run-one-liner (second argv)
                                     :refresh refresh :strict strict
                                     :dry-run dry-run :model model :plugins plugins))))
        (t (usage) (uiop:quit 2)))
    (error (e)
      (format *error-output* "allisp: error: ~a~%" e)
      (uiop:quit 3))))

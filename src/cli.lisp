(in-package #:allisp)

(defun usage ()
  (format *error-output* "~
usage:
  allisp run <file.lisp> [options]
  allisp run <dir> [options]
  allisp --one-liner \"<form>...\" [options]
  allisp diff <old.result.lisp> <new.result.lisp>

  Evaluate an allisp source file or expression string. Defined forms evaluate deterministically;
  unbound forms are lowered to Lisp code by the LLM oracle; only fully resolved
  generated code is executed by the deterministic evaluator.
  File mode writes <dir>/output/<name>.result.lisp and <name>.trace.lisp.
  Directory mode runs every top-level *.lisp file in <dir> (non-recursive, filename
  order, generated *.result.lisp/*.trace.lisp excluded) as independent runs. Without
  --strict a failing file is recorded and the rest still run; exit is 1 if any file
  failed. With --strict the first failing file aborts the remaining files too.
  One-liner mode prints the final value to standard output.
  Diff mode compares two result files: def-family results match by name,
  others by form; each differing value prints as one (changed|added|removed ...)
  form. Exit 0 when identical, 1 when they differ. No LLM call.

options:
  --backend <b> oracle CLI (claude | codex), default claude
  --model <m>   default oracle model (default: sonnet for claude,
                gpt-5.6-terra for codex)
  --out-dir <dir>
                write result/trace files under <dir> instead of <dir of source>/output/
                (run mode only; in directory mode, shared across all files)
  --refresh     ignore the oracle cache and re-ask every oracle form
  --strict      stop at the first error instead of embedding error values
  --dry-run     no LLM calls; report which forms would go to the oracle
  --no-explore  forbid the oracle to read the repository (agentic context off)
  --plugin <git-url[#revision]>
                fetch and load a trusted ASDF syntax plugin (repeatable)
"))

(defun parse-options (args)
  (let (refresh strict dry-run model backend plugins no-explore out-dir)
    (loop while args
          for option = (pop args)
          do (cond
               ((string= option "--refresh") (setf refresh t))
               ((string= option "--strict") (setf strict t))
               ((string= option "--dry-run") (setf dry-run t))
               ((string= option "--no-explore") (setf no-explore t))
               ((string= option "--model")
                (unless args (error "--model needs a value"))
                (setf model (pop args)))
               ((string= option "--backend")
                (unless args (error "--backend needs a value"))
                (setf backend (pop args)))
               ((string= option "--out-dir")
                (unless args (error "--out-dir needs a directory"))
                (setf out-dir (pop args)))
               ((string= option "--plugin")
                (unless args (error "--plugin needs a Git URL"))
                (push (pop args) plugins))
               (t (error "unknown option: ~a" option))))
    (values refresh strict dry-run model backend (nreverse plugins) no-explore out-dir)))

(defun main (argv)
  (handler-case
      (cond
        ((and (string= (or (first argv) "") "run") (second argv))
         (multiple-value-bind (refresh strict dry-run model backend plugins no-explore out-dir)
             (parse-options (cddr argv))
           (uiop:quit (if (uiop:directory-exists-p (second argv))
                          (run-directory (second argv)
                                        :refresh refresh :strict strict
                                        :dry-run dry-run :model model :backend-name backend :plugins plugins
                                        :agentic (not no-explore) :out-dir out-dir)
                          (run-file (second argv)
                                    :refresh refresh :strict strict
                                    :dry-run dry-run :model model :backend-name backend :plugins plugins
                                    :agentic (not no-explore) :out-dir out-dir)))))
        ((and (string= (or (first argv) "") "diff") (second argv) (third argv))
         (when (cdddr argv)
           (error "diff takes exactly two result files"))
         (uiop:quit (diff-results (second argv) (third argv))))
        ((and (string= (or (first argv) "") "--one-liner") (second argv))
         (multiple-value-bind (refresh strict dry-run model backend plugins no-explore out-dir)
             (parse-options (cddr argv))
           (when out-dir
             (error "--out-dir only applies to run mode"))
           (uiop:quit (run-one-liner (second argv)
                                     :refresh refresh :strict strict
                                     :dry-run dry-run :model model :backend-name backend :plugins plugins
                                     :agentic (not no-explore)))))
        (t (usage) (uiop:quit 2)))
    (error (e)
      (format *error-output* "allisp: error: ~a~%" e)
      (uiop:quit 3))))

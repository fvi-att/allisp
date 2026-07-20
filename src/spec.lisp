(in-package #:allisp)

;;; First-class specifications and the derivation ledger.
;;;
;;; A defspec's clauses are unevaluated data, so everything here works by
;;; reading and hashing S-expressions — no evaluation and no oracle call.
;;; That property is what makes `allisp spec status` zero-cost: the current
;;; clause hash of a spec can be recomputed from the source file alone.

;; ---------------------------------------------------------------- spec shape

(defun spec-property (plist key)
  "Plist lookup returning NIL (not +MISSING+) when absent."
  (let ((v (safe-getf plist key)))
    (unless (eq v +missing+) v)))

(defun normalize-spec-clauses (name clauses)
  "The canonical spec value bound by defspec: the clause plist itself, with
:function defaulted to the spec name. Compatible with the plain plist
convention of the earlier spec-driven workflow, so existing generation verbs
and get-property keep working on it."
  (let ((normalized (if (eq (safe-getf clauses :function) +missing+)
                        (list* :function name clauses)
                        (copy-list clauses))))
    ;; Examples have one canonical storage location even though authoring is
    ;; exclusively through top-level (example ...).
    (if (eq (safe-getf normalized :examples) +missing+)
        (append normalized (list :examples nil))
        normalized)))

(defun invariant-clause-p (clause)
  (and (consp clause)
       (keywordp (first clause))
       (stringp (second clause))
       (null (cddr clause))))

(defun validate-spec-clauses (origin clauses)
  "Deterministic schema check for defspec clauses. Returns NIL when
well-formed, otherwise a first-class error value (also recorded in the run
state). No oracle is involved."
  (labels ((fail (type detail)
             (return-from validate-spec-clauses
               (make-error-value type origin detail))))
    (unless (proper-list-p clauses)
      (fail :spec-malformed-clause "defspec clauses must be a proper list"))
    (when (oddp (length clauses))
      (fail :spec-malformed-clause
            "defspec clauses must form a keyword plist (odd number of elements)"))
    (let ((seen '()))
      (loop for (key value) on clauses by #'cddr
            do (unless (keywordp key)
                 (fail :spec-malformed-clause
                       (format nil "clause key ~a is not a keyword" key)))
               (when (member key seen)
                 (fail :spec-duplicate-clause
                       (format nil "clause ~a appears twice" key)))
               (push key seen)
               (case key
                 (:invariants
                  (unless (proper-list-p value)
                    (fail :spec-malformed-clause ":invariants must be a list"))
                  (let ((names '()))
                    (dolist (clause value)
                      (unless (invariant-clause-p clause)
                        (fail :spec-malformed-clause
                              (format nil "invariant ~a must be (:name \"one sentence\")"
                                      (form-summary clause))))
                      (when (member (first clause) names)
                        (fail :spec-duplicate-invariant
                              (format nil "invariant ~a appears twice" (first clause))))
                      (push (first clause) names))))
                 (:examples
                  (fail :spec-inline-examples
                        "write examples as top-level (example <spec> ...), not a :examples clause"))))
      nil)))

(defun spec-invariant-clauses (spec)
  (let ((v (spec-property spec :invariants)))
    (and (listp v) v)))

(defun spec-invariant-names (spec)
  (mapcar #'first (remove-if-not #'consp (spec-invariant-clauses spec))))

(defun spec-invariant-text (spec name)
  "The clause sentence for invariant NAME, matched by symbol name so both
keywords and plain symbols address it."
  (second (find-if (lambda (clause)
                     (and (consp clause) (symbolp (first clause))
                          (symbolp name) name
                          (string-equal (symbol-name (first clause))
                                        (symbol-name name))))
                   (spec-invariant-clauses spec))))

(defun spec-example-list (spec)
  (let ((v (spec-property spec :examples)))
    (and (listp v) v)))

(defun spec-example-by-name (spec name)
  (find name (spec-example-list spec)
        :key (lambda (example) (spec-property example :name))
        :test #'eq))

(defun spec-examples-matching-input (spec input)
  (remove-if-not
   (lambda (example) (equal input (spec-property example :in)))
   (spec-example-list spec)))

(defun replace-spec-examples (spec examples)
  (let ((copy (copy-tree spec)))
    (setf (getf copy :examples) examples)
    copy))

;; ---------------------------------------------------------------- clause hash

(defun spec-clause-hash (name clauses)
  "Content hash of a spec: the printed normalized clause plist. Because the
clauses are unevaluated data, this is computable both from the bound value at
derive time and from the source text at status time, and the two agree."
  (sha256-hex (print-sexp (normalize-spec-clauses name clauses) :pretty nil)))

(defun file-sha256 (path)
  (sha256-hex (uiop:read-file-string path)))

(defun find-defspec-clauses (source-path name)
  "The clause list of (defspec NAME ...) among SOURCE-PATH's top-level forms,
or :NOT-FOUND. Reading only — the file is never evaluated."
  (handler-case
      (loop for form in (read-allisp-file source-path)
            when (and (consp form) (symbolp (car form))
                      (string= (symbol-name (car form)) "DEFSPEC")
                      (eq (second form) name))
              return (cddr form)
            finally (return :not-found))
    (error () :not-found)))

(defun source-form-definition-info (form)
  "Reader-only counterpart of the evaluator's definition registry."
  (when (and (consp form) (symbolp (first form)))
    (let ((head (symbol-name (first form)))
          (arg (second form)))
      (cond
        ((member head '("DEFUN" "DEFMACRO" "DEF" "DEFVAR" "DEFPARAMETER"
                        "DEFSPEC")
                 :test #'string=)
         (when (symbolp arg) (values arg (intern head :keyword))))
        ((string= head "DEFINE")
         (cond ((symbolp arg) (values arg :define-value))
               ((and (consp arg) (symbolp (first arg)))
                (values (first arg) :define-function))))))))

(defun source-example-form-p (form)
  (and (consp form) (symbolp (first form))
       (string= (symbol-name (first form)) "EXAMPLE")))

(defun source-spec-hash (source-path target-name)
  "Reconstruct TARGET-NAME, its top-level examples, and transitive declared
dependencies from SOURCE-PATH. Returns (values HASH NIL), or
(values NIL deterministic-error-detail)."
  (handler-case
      (let ((definitions (make-hash-table :test #'eq))
            (specs (make-hash-table :test #'eq))
            (example-names (make-hash-table :test #'eq))
            (context-totals (make-hash-table :test #'eq))
            (derived (make-hash-table :test #'eq))
            (order 0))
        (dolist (form (read-allisp-file source-path))
          (incf order)
          (multiple-value-bind (name kind) (source-form-definition-info form)
            (when name
              (when (and (eq kind :defspec) (gethash name specs))
                (return-from source-spec-hash
                  (values nil (list :type :spec-redefined :form form))))
              (let ((value
                      (when (eq kind :defspec)
                        (let ((err (validate-spec-clauses form (cddr form))))
                          (when err
                            (return-from source-spec-hash
                              (values nil (rest err))))
                          (normalize-spec-clauses name (cddr form))))))
                (let ((record (list :name name :kind kind :form form
                                    :order order :value value)))
                  (setf (gethash name definitions) record)
                  (when (eq kind :defspec)
                    (setf (gethash name specs) record
                          (gethash name example-names)
                          (make-hash-table :test #'eq)
                          (gethash name context-totals) 0))))))
          (when (source-example-form-p form)
            (let* ((name (second form))
                   (fields (cddr form))
                   (record (and (symbolp name) (gethash name specs)))
                   (schema (plist-schema-error
                            fields +example-allowed-fields+
                            '(:name :in :out :context))))
              (when schema
                (return-from source-spec-hash
                  (values nil (list :type :example-malformed
                                    :form form :detail schema))))
              (unless record
                (return-from source-spec-hash
                  (values nil (list :type :example-spec-not-found
                                    :form form))))
              (when (gethash name derived)
                (return-from source-spec-hash
                  (values nil (list :type :example-after-derive
                                    :form form))))
              (let* ((spec (spec-property record :value))
                     (example-name (spec-property fields :name))
                     (context (spec-property fields :context))
                     (covers (let ((v (safe-getf fields :covers)))
                               (unless (eq v +missing+) v)))
                     (deps (let ((v (safe-getf fields :depends-on)))
                             (unless (eq v +missing+) v))))
                (unless (keywordp example-name)
                  (return-from source-spec-hash
                    (values nil (list :type :example-invalid-name :form form))))
                (when (gethash example-name (gethash name example-names))
                  (return-from source-spec-hash
                    (values nil (list :type :example-duplicate-name :form form))))
                (unless (and (stringp context)
                             (> (length
                                 (string-trim
                                  '(#\Space #\Tab #\Newline #\Return)
                                  context))
                                0)
                             (<= (length context) +example-context-limit+))
                  (return-from source-spec-hash
                    (values nil (list :type :example-invalid-context :form form))))
                (when (> (+ (gethash name context-totals) (length context))
                         +spec-context-limit+)
                  (return-from source-spec-hash
                    (values nil (list :type :spec-context-too-large :form form))))
                (when (not (eq (safe-getf fields :covers) +missing+))
                  (unless (and covers (proper-list-p covers)
                               (every #'keywordp covers)
                               (= (length covers)
                                  (length (remove-duplicates covers :test #'eq)))
                               (every (lambda (key)
                                        (member key (spec-invariant-names spec)
                                                :test #'eq))
                                      covers))
                    (return-from source-spec-hash
                      (values nil (list :type :example-invalid-covers
                                        :form form)))))
                (when (not (eq (safe-getf fields :depends-on) +missing+))
                  (unless (and deps (proper-list-p deps)
                               (every (lambda (x)
                                        (and x (symbolp x) (not (keywordp x))
                                             (gethash x definitions)))
                                      deps)
                               (= (length deps)
                                  (length (remove-duplicates deps :test #'eq))))
                    (return-from source-spec-hash
                      (values nil (list :type :example-dependency-not-found
                                        :form form)))))
                (setf (gethash example-name (gethash name example-names)) t
                      (gethash name context-totals)
                      (+ (gethash name context-totals) (length context))
                      (getf record :value)
                      (replace-spec-examples
                       spec (append (spec-example-list spec)
                                    (list (copy-tree fields))))))))
          (when (and (consp form) (symbolp (first form))
                     (string= (symbol-name (first form)) "DERIVE"))
            (let* ((from (safe-getf (cddr form) :from))
                   (names (cond ((symbolp from) (list from))
                                ((and (listp from) (every #'symbolp from)) from)
                                (t '()))))
              (dolist (name names)
                (setf (gethash name derived) t)))))
        ;; A cycle is an invalid source even though the hash walker below is
        ;; cycle-safe; runtime example registration rejects the same graph.
        (labels ((spec-deps (name)
                   (let ((record (gethash name specs)))
                     (remove-if-not
                      (lambda (dep) (gethash dep specs))
                      (and record
                           (remove-duplicates
                            (loop for ex in
                                  (spec-example-list
                                   (spec-property record :value))
                                  append
                                  (or (spec-property ex :depends-on) '()))
                            :test #'eq)))))
                 (reaches (start goal seen)
                   (or (eq start goal)
                       (and (not (member start seen :test #'eq))
                            (some (lambda (next)
                                    (reaches next goal (cons start seen)))
                                  (spec-deps start))))))
          (maphash
           (lambda (name record)
             (declare (ignore record))
             (when (some (lambda (dep) (reaches dep name '()))
                         (spec-deps name))
               (return-from source-spec-hash
                 (values nil (list :type :spec-dependency-cycle
                                   :spec name)))))
           specs))
        (let ((target (gethash target-name specs)))
          (unless target
            (return-from source-spec-hash (values nil :not-found)))
          (let ((seen (make-hash-table :test #'eq))
                (records '()))
            (labels ((direct (spec)
                       (remove-duplicates
                        (loop for ex in (spec-example-list spec)
                              append (or (spec-property ex :depends-on) '()))
                        :test #'eq))
                     (visit (name)
                       (unless (or (eq name target-name) (gethash name seen))
                         (setf (gethash name seen) t)
                         (let ((record (gethash name definitions)))
                           (when record
                             (push record records)
                             (dolist (sym
                                      (form-symbols
                                       (if (eq (spec-property record :kind)
                                               :defspec)
                                           (spec-property record :value)
                                           (spec-property record :form))))
                               (when (gethash sym definitions) (visit sym)))
                             (when (eq (spec-property record :kind) :defspec)
                               (dolist (dep
                                        (direct (spec-property record :value)))
                                 (visit dep))))))))
              (dolist (dep (direct (spec-property target :value))) (visit dep)))
            (setf records
                  (sort records #'<
                        :key (lambda (r) (spec-property r :order))))
            (values
             (sha256-hex
              (print-sexp
               (list
                :spec (spec-property target :value)
                :dependencies
                (mapcar
                 (lambda (record)
                   (list (spec-property record :name)
                         (if (eq (spec-property record :kind) :defspec)
                             (spec-property record :value)
                             (spec-property record :form))))
                 records))
               :pretty nil))
             nil))))
    (error (e)
      (values nil (list :type :source-read-error
                        :detail (princ-to-string e))))))

;; ---------------------------------------------------------------- ledger

(defun ledger-path (root)
  (merge-pathnames ".allisp/derive.lisp"
                   (uiop:ensure-directory-pathname root)))

(defun root-relative (path root)
  "PATH as a project-root-relative namestring when it lies under ROOT,
otherwise the absolute namestring."
  (let ((p (namestring path))
        (r (namestring (uiop:ensure-directory-pathname root))))
    (if (and (> (length p) (length r))
             (string= r p :end2 (length r)))
        (subseq p (length r))
        p)))

(defun derivation-entry-p (form)
  (and (consp form) (symbolp (car form))
       (string= (symbol-name (car form)) "DERIVATION")))

(defun ledger-read (root)
  (let ((path (ledger-path root)))
    (if (probe-file path)
        (handler-case
            (remove-if-not #'derivation-entry-p (read-allisp-file path))
          (error () '()))
        '())))

(defun ledger-write (root entries)
  (let ((path (ledger-path root)))
    (ensure-directories-exist path)
    (with-open-file (out path :direction :output :if-exists :supersede
                              :external-format :utf-8)
      (format out ";; allisp derivation ledger. Written by (derive ...), read by `allisp spec status`.~%~
                   ;; One (derivation ...) per target, keyed by :target (project-root relative).~%~%")
      (dolist (e entries)
        (write-string (print-sexp e) out)
        (format out "~%~%")))
    path))

(defun ledger-record (root &key target source from via proofs ignore-skip)
  "Insert or replace the ledger entry for TARGET. FROM is an alist of
(spec-name . bound-value); the recorded hash is over the normalized clause
plist, which is exactly what spec-clause-hash recomputes from the source."
  (let* ((rel-target (root-relative target root))
         (entry (list* (usym "DERIVATION")
                       (list :v 2
                             :target rel-target
                             :source (and source (root-relative source root))
                             :from (mapcar #'car from)
                             :from-sha256
                             (mapcar (lambda (pair)
                                       (let ((proof (find (car pair) proofs
                                                          :key #'first)))
                                         (list (car pair)
                                               (or (spec-property
                                                    (rest proof) :sha256)
                                                   (sha256-hex
                                                    (print-sexp (cdr pair)
                                                                :pretty nil))))))
                                     from)
                             :proofs proofs
                             :ignore-skip (and ignore-skip t)
                             :via via
                             :target-sha256 (and (uiop:file-exists-p target)
                                                 (file-sha256 target))
                             :generated-at (timestamp-string))))
         (entries (ledger-read root))
         (existing (find rel-target entries
                         :key (lambda (e) (spec-property (cdr e) :target))
                         :test #'equal)))
    (ledger-write root
                  (if existing
                      (substitute entry existing entries)
                      (append entries (list entry))))
    entry))

;; ---------------------------------------------------------------- spec status

(defun status-for-entry (entry root)
  "One status S-expression for a ledger ENTRY. Zero LLM calls: freshness is
decided by re-reading the source's defspec clauses and re-hashing files."
  (let* ((plist (cdr entry))
         (version (or (spec-property plist :v) 1))
         (rel-target (spec-property plist :target))
         (target (merge-pathnames rel-target
                                  (uiop:ensure-directory-pathname root)))
         (rel-source (spec-property plist :source))
         (source (and rel-source
                      (merge-pathnames rel-source
                                       (uiop:ensure-directory-pathname root))))
         (recorded-hash (spec-property plist :target-sha256)))
    (cond
      ((or (not (integerp version)) (< version 2))
       (list (usym "UNKNOWN") :target rel-target
             :detail "legacy derivation ledger entry; re-run the source to record proof metadata"))
      ((not (uiop:file-exists-p target))
       (list (usym "MISSING") :target rel-target
             :detail "target file does not exist; re-run the source file"))
      ((and recorded-hash
            (not (string= (file-sha256 target) recorded-hash)))
       (list (usym "DRIFTED") :target rel-target
             :detail "target was edited after generation; the edit is not in the spec and regeneration will overwrite it"))
      ((null source)
       (list (usym "UNKNOWN") :target rel-target
             :detail "no source file recorded"))
      ((not (uiop:file-exists-p source))
       (list (usym "UNKNOWN") :target rel-target
             :detail (format nil "recorded source ~a not found" rel-source)))
      (t
       (let ((stale nil) (unknown nil))
         (dolist (name (spec-property plist :from))
           (multiple-value-bind (current source-error)
               (source-spec-hash source name)
             (let (
                 (recorded (second (find name (spec-property plist :from-sha256)
                                         :key #'first))))
             (cond (source-error
                    (setf unknown (list name source-error)))
                   ((not (and (stringp recorded)
                              (string= current recorded)))
                    (setf stale name))))))
         (cond
           (stale
            (list (usym "STALE") :target rel-target :from stale
                   :detail "spec clauses changed since generation; re-run the source file to regenerate"))
           (unknown
            (if (and (consp unknown) (consp (second unknown)))
                (list (usym "INVALID") :target rel-target :spec (first unknown)
                      :error (second unknown))
                (list (usym "UNKNOWN") :target rel-target :from unknown
                      :detail "spec not found as a defspec in the recorded source")))
           (t
            (let* ((proofs (spec-property plist :proofs))
                   (proof (and proofs (first proofs))))
              (append (list (usym "FRESH") :target rel-target)
                      (when proof
                        (list :check-status
                              (spec-property (rest proof) :check-status)
                              :probe-status
                              (spec-property (rest proof) :probe-status)))
                   (when (and (spec-property plist :verified-at)
                              (equal (spec-property plist :verified-sha256)
                                     recorded-hash))
                        (list :verified t)))))))))))

(defun spec-status (root &key (out *standard-output*))
  "Report the freshness of every ledger entry under ROOT as one S-expression
per target: (fresh ...) / (stale ...) / (drifted ...) / (missing ...) /
(unknown ...). Returns the exit code: 0 when everything is fresh, 1
otherwise. No LLM call is ever made."
  (let* ((root (uiop:ensure-directory-pathname (truename root)))
         (entries (ledger-read root))
         (fresh 0)
         (attention 0))
    (format out ";; allisp spec status~%;; root: ~a~%;; ledger: ~a (~a entries)~%~%"
            (namestring root) (namestring (ledger-path root)) (length entries))
    (dolist (entry entries)
      (let ((status (status-for-entry entry root)))
        (if (string= (symbol-name (first status)) "FRESH")
            (incf fresh)
            (incf attention))
        (write-string (print-sexp status) out)
        (format out "~%~%")))
    (format out ";; fresh: ~a, needs attention: ~a~%" fresh attention)
    (if (zerop attention) 0 1)))

;; ---------------------------------------------------------------- verify

(defun shell-capture (command directory)
  "Run COMMAND with sh -c in DIRECTORY. Returns (values exit-code stderr)."
  (multiple-value-bind (out err code)
      (uiop:run-program (list "sh" "-c" command)
                        :directory directory
                        :ignore-error-status t
                        :output '(:string :stripped t)
                        :error-output '(:string :stripped t))
    (declare (ignore out))
    (values code err)))

(defun string-tail (s limit)
  (cond ((null s) "")
        ((> (length s) limit) (subseq s (- (length s) limit)))
        (t s)))

(defun stamp-verified (targets source-dir)
  "Mark ledger entries for TARGETS (paths relative to SOURCE-DIR) as
verified, but only when the file on disk is byte-identical to what was
recorded at derive time — a verification of an edited file proves nothing
about the spec."
  (let ((root (and *run* (run-root *run*))))
    (when (and root targets)
      (let ((entries (ledger-read root))
            (changed nil))
        (dolist (tgt targets)
          (let* ((abs (uiop:ensure-absolute-pathname tgt source-dir))
                 (rel (root-relative abs root))
                 (entry (find rel entries
                              :key (lambda (e) (spec-property (cdr e) :target))
                              :test #'equal)))
            (when (and entry (uiop:file-exists-p abs))
              (let ((hash (file-sha256 abs)))
                (when (equal hash (spec-property (cdr entry) :target-sha256))
                  (setf (getf (cdr entry) :verified-at) (timestamp-string)
                        (getf (cdr entry) :verified-sha256) hash
                        changed t))))))
        (when changed
          (ledger-write root entries))))))

(defun execute-verifications (source)
  "Run the (verify ...) commands registered during this run, in registration
order, cwd = SOURCE's directory. Each record is completed destructively in
place — the results list shares the cons, so the result file shows the
outcome. A command whose exit differs from :expect becomes a first-class
error value (recorded for the exit code); with --strict the remaining
commands are marked :skipped and an abort message is returned, else NIL."
  (let ((records (reverse (run-verifications *run*)))
        (dir (uiop:pathname-directory-pathname source))
        (abort-message nil))
    (dolist (record records abort-message)
      (let* ((plist (cdr record))
             (command (spec-property plist :command))
             (targets (spec-property plist :targets))
             (expect (or (spec-property plist :expect) 0)))
        (if abort-message
            (setf (getf (cdr record) :status) :skipped)
            (let ((start (get-internal-real-time)))
              (multiple-value-bind (code err) (shell-capture command dir)
                (let ((secs (float (/ (- (get-internal-real-time) start)
                                      internal-time-units-per-second))))
                  (format *error-output*
                          "~&[allisp]   verify ~s → exit ~a~:[ (expected ~a)~;~*~] (~,1fs)~%"
                          command code (eql code expect) expect secs)
                  (force-output *error-output*)
                  (if (eql code expect)
                      (progn
                        (setf (cdr record)
                              (list :command command :targets targets
                                    :expect expect :status :passed
                                    :exit code :seconds secs))
                        (stamp-verified targets dir))
                      (let ((detail (list* (usym "VERIFICATION")
                                           (list :command command
                                                 :targets targets
                                                 :expect expect :status :failed
                                                 :exit code :seconds secs
                                                 :stderr-tail (string-tail err 400)))))
                        ;; Complete the record as an error value without
                        ;; make-error-value: its --strict signal would escape
                        ;; the runner's per-form handler, so strictness is
                        ;; handled here by skipping the remaining commands.
                        (setf (car record) (usym "ERROR")
                              (cdr record)
                              (list :type :verification-failed
                                    :form (list* (usym "VERIFY") command
                                                 (when targets
                                                   (list :targets targets)))
                                    :detail detail))
                        (when *run*
                          (push (cons (car record) (cdr record))
                                (run-errors *run*))
                          (when (run-strict *run*)
                            (setf abort-message
                                  (format nil "verification failed: ~a → exit ~a (expected ~a)"
                                          command code expect)))))))))))))
  )

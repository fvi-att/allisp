(in-package #:allisp)

;;; The deterministic whitelist: safe CL functions bound as values in the
;;; global environment (allisp is a Lisp-1). Anything outside this list is
;;; guaranteed to fall through to the oracle.

(defun b-funcall (f &rest args) (a-apply f args))
(defun b-apply (f &rest args) (a-apply f (apply #'list* args)))
(defun b-mapcar (f &rest lists) (apply #'mapcar (fnify f) lists))
(defun b-mapcan (f &rest lists) (apply #'mapcan (fnify f) lists))
(defun b-mapc (f &rest lists) (apply #'mapc (fnify f) lists))
(defun b-filter (f list) (remove-if-not (fnify f) list))
(defun b-remove-if (f list) (remove-if (fnify f) list))
(defun b-remove-if-not (f list) (remove-if-not (fnify f) list))
(defun b-find-if (f list) (find-if (fnify f) list))
(defun b-position-if (f list) (position-if (fnify f) list))
(defun b-count-if (f list) (count-if (fnify f) list))
(defun b-every (f &rest lists) (apply #'every (fnify f) lists))
(defun b-some (f &rest lists) (apply #'some (fnify f) lists))
(defun b-reduce (f list &rest keys) (apply #'reduce (fnify f) list keys))
(defun b-sort (list f &rest keys)
  (apply #'sort (copy-seq list) (fnify f)
         (loop for (k v) on keys by #'cddr
               when (eq k :key) append (list :key (fnify v)))))
(defun b-functionp (x) (or (functionp x) (closure-p x)))
(defun b-string-append (&rest strings)
  (apply #'concatenate 'string (mapcar #'string strings)))
(defun b-format (dest control &rest args)
  (apply #'format (and (eq dest t) t) control args))
(defun b-print (x)
  (with-allisp-syntax (format t "~&~a~%" (print-sexp x)))
  x)

(defun b-allocate-memory-block (&key element-type integer-width length
                                     (initialization :uninitialized))
  "Allocate process-local mutable integer storage without reading an
uninitialized element. Reads are gated by a separate initialization bitmap."
  (unless (eq element-type :int)
    (error "allocate-memory-block: unsupported element type ~a" element-type))
  (unless (member integer-width '(32 64))
    (error "allocate-memory-block: integer-width must be 32 or 64"))
  (unless (and (integerp length) (not (minusp length)))
    (error "allocate-memory-block: length must be a non-negative integer"))
  (unless (eq initialization :uninitialized)
    (error "allocate-memory-block: only :uninitialized is currently supported"))
  (%make-managed-memory-block
   :element-type element-type
   :integer-width integer-width
   :length length
   :storage (make-array length
                        :element-type `(signed-byte ,integer-width))
   :initialized (make-array length :element-type 'bit :initial-element 0)))

(defun check-memory-index (block index)
  (unless (managed-memory-block-p block)
    (error "expected a managed memory block"))
  (unless (and (integerp index)
               (<= 0 index)
               (< index (managed-memory-block-length block)))
    (error "memory block index out of bounds: ~a" index)))

(defun b-memory-block-write (block index value)
  (check-memory-index block index)
  (setf (aref (managed-memory-block-storage block) index) value
        (aref (managed-memory-block-initialized block) index) 1)
  value)

(defun b-memory-block-read (block index)
  (check-memory-index block index)
  (unless (= 1 (aref (managed-memory-block-initialized block) index))
    (error "memory block element ~a is uninitialized" index))
  (aref (managed-memory-block-storage block) index))

(defun b-get-property (obj key &rest opts)
  "The DSL's (get-property list key [:default d]): find KEY in LIST by symbol
name (symbols and keywords match each other) and return the next element."
  (let ((default (let ((d (safe-getf opts :default)))
                   (unless (eq d +missing+) d))))
    (if (and (listp obj) (symbolp key))
        (loop for tail = obj then (cdr tail)
              while (and (consp tail) (consp (cdr tail)))
              when (and (symbolp (car tail)) (car tail)
                        (string-equal (symbol-name (car tail)) (symbol-name key)))
                return (cadr tail)
              finally (return default))
        default)))

(defparameter +builtins+
  (list
   ;; lists
   "CAR" #'car "CDR" #'cdr "CAAR" #'caar "CADR" #'cadr "CDAR" #'cdar "CDDR" #'cddr
   "CONS" #'cons "LIST" #'list "LIST*" #'list* "APPEND" #'append
   "REVERSE" #'reverse "LENGTH" #'length "NTH" #'nth "NTHCDR" #'nthcdr
   "FIRST" #'first "SECOND" #'second "THIRD" #'third "FOURTH" #'fourth
   "LAST" #'last "BUTLAST" #'butlast "COPY-LIST" #'copy-list
   "ASSOC" #'assoc "MEMBER" #'member "GETF" #'getf
   "REMOVE" #'remove "REMOVE-DUPLICATES" #'remove-duplicates
   "COUNT" #'count "FIND" #'find "POSITION" #'position
   "UNION" #'union "INTERSECTION" #'intersection "SET-DIFFERENCE" #'set-difference
   "SUBSEQ" #'subseq "ELT" #'elt "IDENTITY" #'identity
   ;; numbers
   "+" #'+ "-" #'- "*" #'* "/" #'/
   "=" #'= "/=" #'/= "<" #'< ">" #'> "<=" #'<= ">=" #'>=
   "MIN" #'min "MAX" #'max "ABS" #'abs "MOD" #'mod "REM" #'rem
   "EXPT" #'expt "SQRT" #'sqrt "FLOOR" #'floor "CEILING" #'ceiling
   "ROUND" #'round "TRUNCATE" #'truncate "1+" #'1+ "1-" #'1-
   ;; predicates
   "EQ" #'eq "EQL" #'eql "EQUAL" #'equal "EQUALP" #'equalp
   "NOT" #'not "NULL" #'null "ATOM" #'atom
   "CONSP" #'consp "LISTP" #'listp "SYMBOLP" #'symbolp "STRINGP" #'stringp
   "NUMBERP" #'numberp "INTEGERP" #'integerp "KEYWORDP" #'keywordp
   "ZEROP" #'zerop "EVENP" #'evenp "ODDP" #'oddp "PLUSP" #'plusp "MINUSP" #'minusp
   "FUNCTIONP" #'b-functionp
   "MANAGED-MEMORY-BLOCK-P" #'managed-memory-block-p
   ;; scheme-flavored aliases seen in thought files
   "EQUAL?" #'equal "EQ?" #'eq "NULL?" #'null
   "LIST?" #'listp "SYMBOL?" #'symbolp "STRING?" #'stringp "NUMBER?" #'numberp
   "FILTER" #'b-filter "GET-PROPERTY" #'b-get-property
   ;; strings & symbols
   "STRING" #'string "STRING=" #'string= "STRING<" #'string<
   "STRING-EQUAL" #'string-equal
   "STRING-UPCASE" #'string-upcase "STRING-DOWNCASE" #'string-downcase
   "STRING-TRIM" #'string-trim "STRING-APPEND" #'b-string-append
   "SYMBOL-NAME" #'symbol-name "PRINC-TO-STRING" #'princ-to-string
   "GENSYM" #'gensym "FORMAT" #'b-format "PRINT" #'b-print
   ;; process-local managed memory
   "ALLOCATE-MEMORY-BLOCK" #'b-allocate-memory-block
   "MEMORY-BLOCK-WRITE" #'b-memory-block-write
   "MEMORY-BLOCK-READ" #'b-memory-block-read
   ;; higher-order
   "MAPCAR" #'b-mapcar "MAPCAN" #'b-mapcan "MAPC" #'b-mapc
   "REMOVE-IF" #'b-remove-if "REMOVE-IF-NOT" #'b-remove-if-not
   "FIND-IF" #'b-find-if "POSITION-IF" #'b-position-if "COUNT-IF" #'b-count-if
   "EVERY" #'b-every "SOME" #'b-some "REDUCE" #'b-reduce "SORT" #'b-sort
   "FUNCALL" #'b-funcall "APPLY" #'b-apply))

(defun make-global-env ()
  (let ((env (make-env)))
    (loop for (name fn) on +builtins+ by #'cddr
          do (env-define env (usym name) fn))
    (install-syntax-macros env)
    (install-core-macros env)))

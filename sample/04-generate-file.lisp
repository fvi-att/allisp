;; Build an allisp program as data, then write it to another file.

(defun build-multiplier-program (name factor input)
  `(progn
     (defun ,name (value)
       (* value ,factor))
     (,name ,input)))

(generate-file "output/generated-double.lisp"
  (build-multiplier-program 'double 2 21))

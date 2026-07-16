;; Deterministic evaluation only: every operator is defined by allisp or here.

(defun square (number)
  (* number number))

(defun average (numbers)
  (/ (reduce (lambda (total number) (+ total number))
             numbers
             :initial-value 0)
     (length numbers)))

(def scores '(72 88 91 64))

(pure
  (list :squares (mapcar square scores)
        :average (average scores)
        :passing (filter (lambda (score) (>= score 70)) scores)))

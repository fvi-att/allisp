;; Constraints can appear anywhere in a rule.  They wait until their logic
;; variables are bound, then remove failing branches deterministically.

(goal engineer (aya 8))
(goal engineer (ben 5))
(goal engineer (chika 10))

(goal available-hours (?name ?hours)
  (engineer ?name ?hours)
  (constraint (>= ?hours 8)))

(goal assignable (?name)
  (available-hours ?name ?hours)
  (constraint (<= ?hours 9)))

;; => ((:name aya))
(pure
  (solve (assignable ?name)))

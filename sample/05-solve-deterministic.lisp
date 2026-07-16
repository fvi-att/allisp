;; Prolog-like deduction with facts and recursive goals.  No LLM call.

(goal parent (alice bob))
(goal parent (bob carol))
(goal parent (alice diana))

(goal ancestor (?parent ?child)
  (parent ?parent ?child))

(goal ancestor (?parent ?descendant)
  (parent ?parent ?child)
  (ancestor ?child ?descendant))

;; => ((:who bob) (:who diana) (:who carol))
(pure
  (solve (ancestor alice ?who)))

;; Hybrid deduction: the LLM supplies review data once, and SOLVE uses that
;; data as part of a deterministic goal.

(def deployment-candidates
  '("checkout-api" "catalog-api" "recommendation-api"))

;; Ask for data, not code.  For example:
;; (:approved ("checkout-api" "recommendation-api") :reason "...")
(def release-review
  (llm
    (select-deployment-candidates
      :candidates deployment-candidates
      :criteria '(:tests-passing t :rollback-ready t)
      :return-shape '(:approved (string) :reason string))))

(goal candidate ("checkout-api"))
(goal candidate ("catalog-api"))
(goal candidate ("recommendation-api"))

;; The rule uses the LLM result as a fact-like input.  The constraint itself
;; stays deterministic and never makes an oracle call during search.
(goal approved-for-deployment (?service)
  (candidate ?service)
  (constraint
   (some (lambda (approved)
           (string= ?service approved))
         (get-property release-review :approved :default nil))))

;; => e.g. ((:service "checkout-api") (:service "recommendation-api"))
(solve (approved-for-deployment ?service))

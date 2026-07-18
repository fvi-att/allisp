;; Hybrid evaluation:
;; 1. REVIEW-SCORE expands deterministically.
;; 2. ESTIMATE-RISK-ADJUSTMENT is lowered to Lisp code by the LLM.
;; 3. GET-PROPERTY, +, and LIST process the returned value deterministically.

(def release-context
  '(:service "checkout-api"
    :change "Replace the payment retry policy"
    :tests (:unit :integration)
    :rollback "Feature flag"
    :open-issue "Load test has not run"))

(defmacro review-score (base-score context)
  "Add an LLM-estimated adjustment, then construct the result deterministically."
  `(let ((review
          (estimate-risk-adjustment
            :context ,context
            :return-shape '(:adjustment integer :reason string))))
     (list :base-score ,base-score
           :llm-review review
           :final-score
           (+ ,base-score
              (get-property review :adjustment :default 0)))))

;; The final call expands deterministically to the equivalent of:
;;
;; (let ((review
;;        (estimate-risk-adjustment
;;          :context release-context
;;          :return-shape '(:adjustment integer :reason string))))
;;   (list :base-score 70
;;         :llm-review review
;;         :final-score
;;         (+ 70 (get-property review :adjustment :default 0))))
;;
;; For example, if the oracle generates
;; (quote (:adjustment -12 :reason "Load testing is still open")), the
;; deterministic evaluator produces the plist and the remainder produces
;; :final-score 58.

(review-score 70 release-context)

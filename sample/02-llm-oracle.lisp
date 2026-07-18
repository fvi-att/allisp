;; Staged LLM lowering: classify-release-risk has no deterministic definition.
;; The oracle generates Lisp code; allisp runs it only when fully resolved.

(def release-context
  '(:service "checkout-api"
    :change "Replace the payment retry policy"
    :tests (:unit :integration)
    :rollback "Feature flag"
    :open-issue "Load test has not run"))

(llm
  (classify-release-risk
    :context release-context
    :return-shape
    '(:risk-level symbol
      :reasons (string)
      :recommended-action string)))

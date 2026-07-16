;; LLM pseudo-execution: classify-release-risk has no deterministic definition.

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

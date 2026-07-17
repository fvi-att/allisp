;; Executable ADR: premises are data, the decision is an oracle form.
;;
;; Each oracle call is cached by (prompt version, model, full prompt),
;; and the prompt contains the bindings the form references. Editing one
;; premise therefore re-runs only the oracle forms that depend on it;
;; every other form replays from cache without an LLM call.
;;
;; Try it:
;;   bin/allisp run sample/09-executable-adr.lisp   ; first run: 2 misses
;;   bin/allisp run sample/09-executable-adr.lisp   ; replay: 2 hits, no LLM
;;   (edit budget-premise below, then run again)    ; 1 miss, 1 hit

(def traffic-premise
  '(:peak-orders-per-minute 40
    :growth-per-quarter 0.25))

(def team-premise
  '(:backend-engineers 3
    :oncall-rotation :weekly))

(def budget-premise
  '(:infra-usd-per-month 800))

;; Depends on all three premises.
(def decision
  (llm
    (decide-queue-adoption
      :question "Should order intake call fulfillment directly, or through a message queue?"
      :traffic traffic-premise
      :team team-premise
      :budget budget-premise
      :return-shape
      '(:choice symbol
        :rationale (string)
        :rejected ((:option symbol :reason string))))))

;; Depends only on team-premise: editing budget-premise leaves this cached.
(def revisit-triggers
  (llm
    (plan-revisit-triggers
      :decision-title "queue adoption"
      :team team-premise
      :return-shape '((:trigger string :check string)))))

;; Deterministic audit of the oracle values.
(get-property decision :choice)
(length revisit-triggers)

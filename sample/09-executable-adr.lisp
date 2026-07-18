;; Executable ADR: premises are data, the decision is an oracle form, and
;; the revisit conditions are executable.
;;
;; The oracle plans the revisit triggers ONCE, as data conditions over
;; observable metrics (cached after the first run). From then on the
;; deterministic evaluator re-checks them for free: update OBSERVED below
;; and re-run — whether the decision must be revisited is computed by the
;; Lisp evaluator, not judged again by the LLM.
;;
;; Each oracle call is cached by (prompt version, model, full prompt),
;; and the prompt contains the bindings the form references. Editing one
;; premise therefore re-runs only the oracle forms that depend on it;
;; every other form replays from cache without an LLM call.
;;
;; Try it:
;;   bin/allisp run sample/09-executable-adr.lisp   ; first run: 2 misses
;;   bin/allisp run sample/09-executable-adr.lisp   ; replay: 2 hits, no LLM
;;   (edit observed below, then run again)          ; 0 misses — the trigger
;;                                                  ;  check is deterministic

(def traffic-premise
  '(:peak-orders-per-minute 40
    :growth-per-quarter 0.25))

(def team-premise
  '(:backend-engineers 3
    :oncall-rotation :weekly))

(def budget-premise
  '(:infra-usd-per-month 800))

;; Latest observations, updated as reality changes. Re-running with new
;; numbers costs zero LLM calls.
(def observed
  '(:peak-orders-per-minute 46
    :backend-engineers 3
    :queue-incidents-per-week 0))

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

;; The oracle plans triggers as DATA conditions, not prose: each one names a
;; metric from METRICS-AVAILABLE, a direction, and a threshold. That is the
;; whole LLM output surface — the check itself stays in the evaluator.
(def revisit-triggers
  (llm
    (plan-revisit-triggers
      :decision-title "queue adoption"
      :traffic traffic-premise
      :team team-premise
      :metrics-available '(:peak-orders-per-minute
                           :backend-engineers
                           :queue-incidents-per-week)
      :return-shape '((:trigger string
                       :metric symbol
                       :fires-when symbol  ; at-or-above | at-or-below
                       :threshold number)))))

;; Deterministic: evaluate one planned trigger against the observations.
(defun trigger-fired? (trigger observed)
  (let ((value (get-property observed (get-property trigger :metric)))
        (threshold (get-property trigger :threshold)))
    (if (equal? value nil)
        nil
        (if (string= (string (get-property trigger :fires-when))
                     (string :at-or-above))
            (>= value threshold)
            (<= value threshold)))))

(def fired-triggers
  (filter (lambda (tr) (trigger-fired? tr observed)) revisit-triggers))

;; Deterministic audit of the oracle values.
(get-property decision :choice)

(list :revisit-needed (if fired-triggers t nil)
      :fired (mapcar (lambda (tr) (get-property tr :trigger)) fired-triggers))

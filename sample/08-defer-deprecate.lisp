;; Decision markers are deterministic: DEFER preserves code without running it,
;; while DEPRECATE runs code and retains why the result is no longer preferred.

(def approval-reason "Legal review is still pending")
(def replacement "billing-v2")

(list
 :deferred
 (defer (send-renewal-email customer :template "annual")
        :reason approval-reason)
 :deprecated
 (deprecate (+ 20 22)
            :reason "Use the billing-v2 total instead"
            :replacement replacement))

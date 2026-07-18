;; Convert a markdown runbook into an allisp program. The oracle translates
;; the document under the anti-prose rules: every heading, step, and
;; threshold becomes a structured S-expression (def / defun / plists / a
;; small DSL), never a restated prose string. The value of markdown->lisp is
;; the converted program as data — the forms are NOT executed here (pass
;; :eval t to install them like @use). :out writes the same program to
;; output/deploy-runbook.lisp with a generated-by provenance marker, ready to
;; be run or @use'd on its own.

(def runbook-markdown
"# Deploy runbook

## Preconditions

- CI is green on the release branch
- No open production incident

## Steps

1. Tag the release
2. Deploy to staging and run the smoke tests
3. Deploy to production as a 10% canary for 15 minutes
4. Promote to 100% when the canary error rate stays below 1%

## Rollback

- Roll back immediately when the error rate reaches 1%
")

(markdown->lisp runbook-markdown
  :from :text
  :out "output/deploy-runbook.lisp")

;; Render structured data into a Markdown report and write it to a plain
;; .md file. generate-file writes non-.lisp targets as a raw string (no
;; S-expression header, no generated-by marker), so the whole body must
;; evaluate to a string end-to-end.

(defun render-row (finding)
  (format nil "| ~a | ~a | ~a |~%"
          (get-property finding :severity)
          (get-property finding :area)
          (get-property finding :summary)))

(defun render-report (title findings)
  (format nil "# ~a~%~%| Severity | Area | Summary |~%| --- | --- | --- |~%~{~a~}"
          title
          (mapcar render-row findings)))

(def findings
  (list
    (list :severity "high" :area "cache" :summary "Oracle cache key omits model id in v0")
    (list :severity "medium" :area "cli" :summary "--dry-run does not print skipped LLM call count")
    (list :severity "low" :area "docs" :summary "sample README missing generate-file cross link")))

(generate-file "output/findings-report.md"
  (render-report "Findings Report" findings))

(in-package #:allisp)

(defun sha256-hex (string)
  (ironclad:byte-array-to-hex-string
   (ironclad:digest-sequence
    :sha256 (sb-ext:string-to-octets string :external-format :utf-8))))

(defun cache-dir (root)
  (merge-pathnames ".allisp/oracle/" (uiop:ensure-directory-pathname root)))

(defun cache-path (root hash)
  (merge-pathnames (concatenate 'string hash ".lisp") (cache-dir root)))

(defun cache-get (root hash)
  "Return the cached plist for HASH, or NIL."
  (let ((path (cache-path root hash)))
    (when (probe-file path)
      (handler-case (first (read-allisp-file path))
        (error () nil)))))

(defun cache-put (root hash plist)
  (let ((path (cache-path root hash)))
    (ensure-directories-exist path)
    (with-open-file (out path :direction :output
                              :if-exists :supersede
                              :external-format :utf-8)
      (write-string (print-sexp plist) out)
      (terpri out))
    path))

(defun timestamp-string ()
  (multiple-value-bind (sec min hour day month year) (get-decoded-time)
    (format nil "~4,'0d-~2,'0d-~2,'0dT~2,'0d:~2,'0d:~2,'0d"
            year month day hour min sec)))

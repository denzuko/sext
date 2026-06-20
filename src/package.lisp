;;;; src/package.lisp -- package definition for sext

(defpackage #:sext
  (:use #:cl)
  (:export
   ;; Core dump API
   #:dump-string
   #:dump-file
   ;; Conditions
   #:sext-error
   #:sext-parse-error
   #:sext-file-error
   ;; CLI entry point (also referenced internally as sext::main)
   #:main))

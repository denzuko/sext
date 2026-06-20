;;;; src/main.lisp -- public API and CLI entry point
;;;;
;;;; STATUS: STUB. Not yet implemented.

(in-package #:sext)

(defun dump-string (source)
  "Parse SOURCE (a Common Lisp source string) via Concrete-Syntax-Tree +
   Cleavir CST-to-AST, walk the resulting AST, and return a JSON string.
   Signals SEXT-PARSE-ERROR on malformed source.
   Returns a JSON array (possibly empty) -- one entry per top-level form.
   NOT YET IMPLEMENTED."
  (declare (ignore source))
  (error "sext:dump-string not yet implemented -- see test/fiveam/test-sext.lisp ~
          for the contract this must satisfy."))

(defun dump-file (path)
  "Read and dump the Common Lisp source file at PATH.
   Signals SEXT-FILE-ERROR if PATH does not exist.
   NOT YET IMPLEMENTED."
  (declare (ignore path))
  (error "sext:dump-file not yet implemented."))

(defun main (args)
  "CLI entry point. ARGS is a list of command-line argument strings
   (typically just a single file path). Writes JSON to *standard-output*.
   This is the function the Roswell script (roswell/sext.ros, not yet
   created) should call.
   NOT YET IMPLEMENTED."
  (declare (ignore args))
  (error "sext::main not yet implemented."))

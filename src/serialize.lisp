;;;; src/serialize.lisp -- encode walked AST data structures to JSON
;;;;
;;;; Resolved (issue #4): src/walker.lisp's WALK-AST/WALK-TOP-LEVEL-FORMS
;;;; already fully flatten Cleavir's CLOS AST objects into plain Lisp data
;;;; (hash-tables for JSON objects, vectors for JSON arrays, strings,
;;;; numbers, symbols, and the booleans T/NIL) -- see walker.lisp's file
;;;; header for the full evidence trail on why neither trivial-json-codec
;;;; nor shasht is needed. That means this file needs only a thin pass
;;;; through to a plain JSON writer for already-plain data:
;;;; COM.INUOE.JZON:STRINGIFY, which already natively understands every
;;;; value shape the walker produces (hash-table -> object, vector ->
;;;; array, T/NIL -> true/false, string/integer/float/ratio -> the
;;;; obvious JSON equivalents) with zero further configuration.

(in-package #:sext)

(defun serialize-to-json (walked-data)
  "Encode WALKED-DATA (the output of WALK-AST/WALK-TOP-LEVEL-FORMS --
already-plain hash-tables/vectors/strings/numbers/symbols/booleans, not
raw CLOS AST instances) to a JSON string."
  (com.inuoe.jzon:stringify walked-data))

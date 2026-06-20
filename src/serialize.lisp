;;;; src/serialize.lisp -- encode walked AST data structures to JSON
;;;;
;;;; STATUS: STUB. Not yet implemented.
;;;;
;;;; Decision needed from next session (see CLAUDE.md "JSON serialization"
;;;; section): trivial-json-codec vs shasht for the CLOS-aware encoding
;;;; step, OR if src/walker.lisp's output is already plain plists/hashtables
;;;; (not raw CLOS instances), a plain jzon:stringify may suffice without
;;;; needing a CLOS-aware codec at all -- this depends on whether walk-ast
;;;; fully flattens to plain data or passes CLOS instances through.
;;;; Recommend flattening fully in walk-ast (simpler, more portable across
;;;; JSON backends) and using plain jzon:stringify here unless a concrete
;;;; reason for a CLOS-aware codec emerges during implementation.

(in-package #:sext)

(defun serialize-to-json (walked-data)
  "Encode WALKED-DATA (output of walk-ast, plain Lisp data structures)
   to a JSON string. NOT YET IMPLEMENTED."
  (declare (ignore walked-data))
  (error "sext::serialize-to-json not yet implemented."))

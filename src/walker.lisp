;;;; src/walker.lisp -- walk Cleavir AST class hierarchy
;;;;
;;;; STATUS: STUB. Not yet implemented.
;;;;
;;;; This is the one piece of genuinely new code in sext (see CLAUDE.md
;;;; "Architecture diagram" -- this file is the highlighted "sext walker"
;;;; box). Its job: given a Cleavir AST node (a standard-object instance),
;;;; recursively visit its slots and produce a plain Lisp data structure
;;;; (nested plists/hash-tables) suitable for handoff to src/serialize.lisp.
;;;;
;;;; Before writing this, confirm against Cleavir's actual class
;;;; definitions (Abstract-syntax-tree/ directory in the Cleavir repo):
;;;;   - What is the base AST class? (Likely cleavir-ast:ast or similar)
;;;;   - What introspection does CLOS give us for free here?
;;;;     (closer-mop:class-slots + closer-mop:slot-definition-name
;;;;     is the standard portable way to enumerate slots without
;;;;     per-class hardcoding -- check if this is sufficient or if
;;;;     Cleavir's AST classes need special-casing for any slots that
;;;;     hold circular references, e.g. parent/child links that would
;;;;     produce infinite recursion in a naive walker.)

(in-package #:sext)

(define-condition sext-error (error) ())

(define-condition sext-parse-error (sext-error)
  ((source :initarg :source :reader sext-parse-error-source))
  (:report (lambda (c stream)
             (format stream "sext: failed to parse source: ~A"
                     (sext-parse-error-source c)))))

(define-condition sext-file-error (sext-error)
  ((path :initarg :path :reader sext-file-error-path))
  (:report (lambda (c stream)
             (format stream "sext: file error: ~A" (sext-file-error-path c)))))

(defun walk-ast (ast-node)
  "Walk AST-NODE (a Cleavir AST standard-object) and return a plain Lisp
   data structure (nested plists) representing its structure.
   NOT YET IMPLEMENTED."
  (declare (ignore ast-node))
  (error "sext::walk-ast not yet implemented -- see CLAUDE.md and ~
          GitHub issue tracker for design notes."))

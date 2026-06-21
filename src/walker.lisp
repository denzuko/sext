;;;; src/walker.lisp -- walk Cleavir AST class hierarchy
;;;;
;;;; This is the one piece of genuinely new code in sext (see CLAUDE.md
;;;; "Architecture diagram" -- this file is the highlighted "sext walker"
;;;; box). Its job: given a Cleavir AST node (a standard-object instance),
;;;; recursively visit its slots and produce a plain Lisp data structure
;;;; (nested hash-tables/vectors/scalars) suitable for handoff to
;;;; src/serialize.lisp.
;;;;
;;;; DESIGN -- resolved via direct verification, not assumption (issue #4):
;;;;
;;;; The original design notes asked whether trivial-json-codec or shasht
;;;; could walk Cleavir's actual AST classes "out of the box" via generic
;;;; CLOS-slot introspection. Checked directly against Cleavir's own
;;;; source instead of guessing: Cleavir ships ITS OWN canonical protocol
;;;; for exactly this purpose, CLEAVIR-IO:SAVE-INFO (used internally for
;;;; Cleavir's own model serialization/printing). Every AST class in
;;;; Abstract-syntax-tree/general-purpose-asts.lisp calls
;;;; CLEAVIR-IO:DEFINE-SAVE-INFO with its own meaningful, named slots
;;;; (confirmed by reading the source directly -- e.g. FUNCTION-AST's
;;;; save-info includes :NAME, :DOCSTRING, :LAMBDA-LIST, :BODY-AST;
;;;; CALL-AST's includes :CALLEE-AST, :ARGUMENT-ASTS, :INLINE). This is a
;;;; far better foundation than blind MOP slot introspection (which would
;;;; also surface internal bookkeeping never meant for serialization) and
;;;; than hoping a generic CLOS-JSON codec's defaults happen to produce
;;;; something sensible for an object graph with deliberate sharing.
;;;;
;;;; Given that, NEITHER trivial-json-codec NOR shasht is actually needed:
;;;; this walker does its own recursive descent via SAVE-INFO, fully
;;;; flattening every AST node (and anything reachable from it) down to
;;;; plain hash-tables/vectors/strings/numbers/symbols/booleans before
;;;; handing off to src/serialize.lisp, which only needs a thin JSON
;;;; writer for already-plain data -- COM.INUOE.JZON:STRINGIFY, already a
;;;; dependency (it's what the test suite itself parses output with).
;;;; sext.asd/qlfile have been updated to drop trivial-json-codec/shasht
;;;; accordingly; sext never needed them.
;;;;
;;;; SHARED/REPEATED SUB-OBJECTS: Cleavir's AST is generally tree-shaped,
;;;; but some nodes -- most commonly LEXICAL-VARIABLE/LEXICAL-AST -- are
;;;; deliberately referenced from multiple places (e.g. a variable bound
;;;; once and read or SETQ'd several times). A naive recursive walk would
;;;; re-expand the same subtree every time it's reached, which is at best
;;;; wasteful and at worst unbounded if a true cycle ever exists. This
;;;; walker assigns each AST node a sequential :ID the first time it's
;;;; encountered and emits {"ref": id} on subsequent encounters instead
;;;; of re-expanding -- the standard technique for serializing object
;;;; graphs with sharing (the same idea as *PRINT-CIRCLE*), and useful in
;;;; its own right for downstream Rego/SARIF correlation.

(in-package #:sext)

(define-condition sext-error (error) ())

(define-condition sext-parse-error (sext-error)
  ((source :initarg :source :reader sext-parse-error-source)
   (cause :initarg :cause :initform nil :reader sext-parse-error-cause
          :documentation "The real underlying condition that caused
this error (a reader error, a Cleavir NO-FUNCTION-INFO error, or
anything else DUMP-STRING's handler-case caught), if one is known.
NIL when SEXT-PARSE-ERROR is signalled directly rather than via that
handler-case -- callers should not assume this is always populated."))
  (:report (lambda (c stream)
             (format stream "sext: failed to parse source~@[: ~A~]~@[~%~%~A~]"
                     (sext-parse-error-cause c)
                     (sext-parse-error-source c)))))

(define-condition sext-file-error (sext-error)
  ((path :initarg :path :reader sext-file-error-path))
  (:report (lambda (c stream)
             (format stream "sext: file error: ~A" (sext-file-error-path c)))))

(defvar *seen* nil
  "Identity hash-table (EQ-keyed) mapping AST objects already encoded in
the current walk to their assigned integer id. NIL outside a walk;
bound fresh by WALK-TOP-LEVEL-FORMS, or by WALK-AST itself when called
standalone with no enclosing walk in progress.")

(defvar *next-id* 0
  "Counter for assigning ids to AST objects as they're first encountered
during the current walk.")

(defun %symbol-json-string (symbol)
  "Render SYMBOL as a JSON-friendly string. Standard-case (read as
upper-case, unescaped) symbol names are downcased for readability,
matching how *PRINT-CASE* :DOWNCASE conventionally renders them;
genuinely mixed-case symbols (created via |...| escapes) are left
exactly as interned, since downcasing would lose information there."
  (let ((name (symbol-name symbol)))
    (if (string= name (string-upcase name))
        (string-downcase name)
        name)))

(defun %walk (value)
  "Recursively convert VALUE -- anything reachable from a Cleavir AST
node's SAVE-INFO, which in practice means AST nodes, lists (including
mixed-shape lambda lists), symbols, strings, numbers, the booleans
T/NIL, and (specifically via the :ORIGIN slot every AST node has)
Concrete-Syntax-Tree CST objects -- into plain data suitable for
COM.INUOE.JZON:STRINGIFY. Falls back to a printed-string representation
for any value kind not handled explicitly, so the walker never crashes
on an unanticipated slot value; 'dump everything, faithfully' is
honored as far as JSON's value model allows, with graceful (and rare)
degradation beyond that."
  (cond
    ((typep value 'cleavir-ast:ast) (%walk-ast-node value))
    ((eq value t) t)
    ((null value) nil)
    ((typep value 'concrete-syntax-tree:cst)
     ;; A CST's default PRINT-OBJECT includes an opaque, non-deterministic
     ;; memory address ("#<CONS-CST raw: ... {1002DC5813}>"), which would
     ;; make dump-string's output non-reproducible run-to-run for
     ;; identical input -- a real defect for a tool meant to feed
     ;; reproducible supply-chain/SBOM tooling. CONCRETE-SYNTAX-TREE:RAW
     ;; is the library's own accessor for "the underlying s-expression,"
     ;; with no such noise; walk that instead. (CONCRETE-SYNTAX-TREE:SOURCE
     ;; is also available and would give true source-location info, but is
     ;; NIL throughout sext's current pipeline, since dump-string/dump-file
     ;; don't bind Eclector's source-tracking client; a future issue could
     ;; wire that up for line/column info in "origin" if needed.)
     (%walk (concrete-syntax-tree:raw value)))
    ((consp value) (coerce (mapcar #'%walk value) 'vector))
    ((symbolp value) (%symbol-json-string value))
    ((stringp value) value)
    ((and (numberp value) (not (complexp value))) value)
    ((vectorp value) (coerce (map 'list #'%walk value) 'vector))
    (t (princ-to-string value))))

(defun %walk-ast-node (ast)
  (let ((existing-id (gethash ast *seen*)))
    (if existing-id
        (let ((ref (make-hash-table :test 'equal)))
          (setf (gethash "ref" ref) existing-id)
          ref)
        (let ((id (incf *next-id*))
              (obj (make-hash-table :test 'equal)))
          (setf (gethash ast *seen*) id)
          (setf (gethash "id" obj) id)
          (setf (gethash "type" obj) (%symbol-json-string (class-name (class-of ast))))
          (dolist (info (cleavir-io:save-info ast))
            (destructuring-bind (initarg reader) info
              (setf (gethash (string-downcase (symbol-name initarg)) obj)
                    (%walk (funcall reader ast)))))
          obj))))

(defun walk-ast (ast-node)
  "Walk AST-NODE (a Cleavir AST standard-object) and return a plain Lisp
data structure (nested hash-tables/vectors) representing its structure.
May be called standalone (creates fresh id-numbering/sharing state) or
as part of a larger walk via WALK-TOP-LEVEL-FORMS (shares that state)."
  (check-type ast-node cleavir-ast:ast)
  (if *seen*
      (%walk-ast-node ast-node)
      (let ((*seen* (make-hash-table :test 'eq))
            (*next-id* 0))
        (%walk-ast-node ast-node))))

(defun walk-top-level-forms (ast-nodes)
  "Walk a list of top-level Cleavir AST nodes (one per top-level form read
from source, in source order) into a single vector -- the JSON-array
shape sext:dump-string/dump-file produce -- sharing object-id numbering
and reference-deduplication across the whole batch."
  (let ((*seen* (make-hash-table :test 'eq))
        (*next-id* 0))
    (coerce (mapcar #'walk-ast ast-nodes) 'vector)))

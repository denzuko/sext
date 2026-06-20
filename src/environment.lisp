;;;; src/environment.lisp -- bridge cleavir-environment/cleavir-ctype to a
;;;; live SBCL image, plus a small, explicitly-tracked set of portable
;;;; macro-expansion overrides.
;;;;
;;;; STATUS: verified working for the DUMP-1..7 fixture shapes (defun,
;;;; defun+docstring, multiple top-level forms). NOT YET fully working for
;;;; DUMP-8 (LOOP) or DUMP-9 (DEFMACRO) -- see "KNOWN OPEN ISSUES" below.
;;;; This file is issue #3's deliverable (confirm dependency integration);
;;;; making DUMP-8/DUMP-9 pass is issue #5's job.
;;;;
;;;; WHY THIS FILE EXISTS AT ALL (not anticipated by the original CLAUDE.md
;;;; design notes -- discovered during issue #3 verification):
;;;;
;;;; cleavir-cst-to-ast's CST-TO-AST entry point requires a SYSTEM object
;;;; (a pure discriminator, no behavior of its own) and an ENVIRONMENT
;;;; satisfying the cleavir-environment generic-function protocol
;;;; (variable-info, function-info, optimize-info, declarations,
;;;; type-expand, eval, cst-eval) plus the cleavir-ctype protocol (top,
;;;; bottom, function, function-required, etc., used internally whenever a
;;;; function call is converted). Neither protocol ships a default/no-op
;;;; implementation -- a client must supply one. Cleavir's own repo ships
;;;; example bridges (Environment/Examples/{hostile,sbcl}.lisp) but they
;;;; are written against an older version of the cleavir-environment
;;;; protocol (e.g. OPTIMIZE-INFO used to take 1 argument, now takes 2) and
;;;; do not load as-is against current Cleavir. This file is sext's own,
;;;; current, from-scratch replacement, verified by direct testing.
;;;;
;;;; KNOWN OPEN ISSUES (confirmed via direct testing, not theoretical):
;;;;
;;;; Several of SBCL's own standard-macro implementations call private
;;;; SB-C internals directly on whatever environment object their expander
;;;; function receives, rather than going through the portable SB-CLTL2
;;;; API. This breaks when that environment is one of cleavir-environment's
;;;; augmentation-chain objects (TAG, BLOCK, VARIABLE-TYPE, etc.) instead of
;;;; a genuine SB-KERNEL:LEXENV. Confirmed instances so far:
;;;;   - CL:DEFUN, CL:DEFMACRO (expand via SB-INT:NAMED-LAMBDA, which
;;;;     Cleavir's FUNCTION converter correctly rejects as non-ANSI) --
;;;;     WORKAROUND APPLIED below (portable expanders).
;;;;   - CL:WHEN, CL:UNLESS, when their body is a single (GO tag) form
;;;;     (SBCL's "prognify" fast path calls SB-C::%COERCE-TO-POLICY on the
;;;;     env argument) -- WORKAROUND APPLIED below.
;;;;   - CL:LOOP itself (independent of the above) -- WORKAROUND APPLIED:
;;;;     delegate to Khazern (s-expressionists/Khazern, a fully portable
;;;;     LOOP implementation, same org as Cleavir, used by SICL/Clasp for
;;;;     exactly this reason) instead of SBCL's native LOOP.
;;;;   - STILL BROKEN: Khazern's own expansion uses CL:LABELS (fine, that's
;;;;     a special operator Cleavir converts natively) but the accumulator
;;;;     update inside it is INCF, and separately sext's own portable
;;;;     DEFMACRO expander uses DESTRUCTURING-BIND -- both are standard
;;;;     MACROS (not special operators), and both have been observed to
;;;;     fail the same way ("is not of type (OR SB-C::ABSTRACT-LEXENV
;;;;     NULL) when binding SB-IMPL::ENV") when expanded through this
;;;;     bridge. NOT YET FIXED. Two candidate directions for issue #5:
;;;;       (a) keep extending the portable-override allowlist one macro at
;;;;           a time as BDD specs surface each failure (consistent with
;;;;           project discipline, but plausibly whack-a-mole -- SBCL's
;;;;           "leaky" macros are not yet known to be a finite, enumerable
;;;;           set), or
;;;;       (b) adopt a portable standard-macro layer wholesale (the same
;;;;           category of project as Khazern, but for SETF/INCF/DECF/
;;;;           DESTRUCTURING-BIND/etc.) instead of bridging to SBCL's
;;;;           native versions of these at all, and reserve the live-SBCL
;;;;           bridge for genuinely user-defined macros and true unknowns
;;;;           only.
;;;;     This decision should be made explicitly at the start of issue #5,
;;;;     not implicitly by whichever fix happens to compile first.

(in-package #:sext)

(eval-when (:compile-toplevel :load-toplevel :execute)
  (require :sb-cltl2))

(defclass sext-system ()
  ()
  (:documentation "Pure discriminator object for Cleavir's generic-function
dispatch. Carries no state of its own -- see Cleavir's README on the
SYSTEM parameter convention."))

(defvar *system* (make-instance 'sext-system))

;;; --- cleavir-ctype <-> ctype glue -----------------------------------------
;;;
;;; `ctype` (s-expressionists' separate, free-standing type-representation
;;; library, on Quicklisp as "ctype"/"ctype/tfun") is the concrete backend
;;; Cleavir's own Example/ frontend uses for cleavir-ctype. Confirmed
;;; empirically: without this glue, any ordinary function call (e.g.
;;; `(+ a b)`) fails inside CLEAVIR-CST-TO-AST::MAKE-CALL trying to call
;;; CLEAVIR-CTYPE:FUNCTION-REQUIRED on a bare CL:T value. sext has no need
;;; for accurate type checking/inference (it dumps structure, not types),
;;; so only the minimal set of methods CST-to-AST's call-conversion path
;;; actually exercises are implemented here, always producing/consuming an
;;; "unconstrained function of anything" ctype.

(defmethod cleavir-ctype:top ((system sext-system)) (ctype:top))
(defmethod cleavir-ctype:bottom ((system sext-system)) (ctype:bot))
(defmethod cleavir-ctype:values-top ((system sext-system)) (ctype:values-top))
(defmethod cleavir-ctype:values-bottom ((system sext-system)) (ctype:values-bot))

(defmethod cleavir-ctype:function
    (req opt rest keyp keys aokp returns (system sext-system))
  (ctype:cfunction (make-instance 'ctype:lambda-list
                                   :required req :optional opt :rest rest
                                   :keyp keyp :keys keys :aokp aokp)
                   returns))

(defmethod cleavir-ctype:functionp (ctype (system sext-system))
  (typep ctype 'ctype:cfunction))

(defmethod cleavir-ctype:function-required ((ctype ctype:cfunction) (system sext-system))
  (ctype:lambda-list-required (ctype:cfunction-lambda-list ctype)))
(defmethod cleavir-ctype:function-optional ((ctype ctype:cfunction) (system sext-system))
  (ctype:lambda-list-optional (ctype:cfunction-lambda-list ctype)))
(defmethod cleavir-ctype:function-rest ((ctype ctype:cfunction) (system sext-system))
  (ctype:lambda-list-rest (ctype:cfunction-lambda-list ctype)))
(defmethod cleavir-ctype:function-keysp ((ctype ctype:cfunction) (system sext-system))
  (ctype:lambda-list-keyp (ctype:cfunction-lambda-list ctype)))
(defmethod cleavir-ctype:function-keys ((ctype ctype:cfunction) (system sext-system))
  (ctype:lambda-list-key (ctype:cfunction-lambda-list ctype)))
(defmethod cleavir-ctype:function-allow-other-keys-p ((ctype ctype:cfunction) (system sext-system))
  (ctype:lambda-list-aokp (ctype:cfunction-lambda-list ctype)))
(defmethod cleavir-ctype:function-values ((ctype ctype:cfunction) (system sext-system))
  (ctype:cfunction-returns ctype))

(defmethod cleavir-ctype:values (required optional rest (system sext-system))
  (ctype:cvalues required optional rest))

(defun %unconstrained-function-type (system)
  "An unconstrained function ctype: (function (&rest t) (values &rest t))."
  (cleavir-ctype:function
   nil nil (cleavir-ctype:top system) nil nil nil
   (cleavir-ctype:values nil nil (cleavir-ctype:top system) system)
   system))

;;; --- cleavir-environment <-> SB-CLTL2 glue --------------------------------

(defmethod cleavir-environment:variable-info
    ((system sext-system) (env sb-kernel:lexenv) symbol)
  (multiple-value-bind (binding local-p decls)
      (sb-cltl2:variable-information symbol env)
    (declare (ignore decls))
    (ecase binding
      ((nil) nil)
      ((:constant)
       (make-instance 'cleavir-environment:constant-variable-info
                       :value (symbol-value symbol) :name symbol))
      ((:special :global)
       (make-instance 'cleavir-environment:special-variable-info
                       :global-p (not local-p) :name symbol
                       :type (cleavir-ctype:top system)))
      ((:lexical)
       (make-instance 'cleavir-environment:lexical-variable-info
                       :name symbol :identity symbol
                       :type (cleavir-ctype:top system)))
      ((:symbol-macro)
       (make-instance 'cleavir-environment:symbol-macro-info
                       :expansion (macroexpand-1 symbol env) :name symbol
                       :type (cleavir-ctype:top system))))))

(defmethod cleavir-environment:function-info
    ((system sext-system) (env sb-kernel:lexenv) function-name)
  (multiple-value-bind (binding local-p decls)
      (sb-cltl2:function-information function-name env)
    (declare (ignore decls))
    (when (and (eq binding :special-form) (not local-p)
               (symbolp function-name) (macro-function function-name))
      (setf binding :macro))
    (ecase binding
      ((nil) nil)
      ((:function)
       (if local-p
           (make-instance 'cleavir-environment:local-function-info
                           :name function-name :identity function-name
                           :type (%unconstrained-function-type system))
           (make-instance 'cleavir-environment:global-function-info
                           :name function-name
                           :type (%unconstrained-function-type system)
                           :compiler-macro (compiler-macro-function function-name))))
      ((:macro)
       (if local-p
           (make-instance 'cleavir-environment:local-macro-info
                           :name function-name
                           :expander (macro-function function-name env))
           (make-instance 'cleavir-environment:global-macro-info
                           :name function-name
                           :expander (macro-function function-name)
                           :compiler-macro (compiler-macro-function function-name))))
      ((:special-form)
       (make-instance 'cleavir-environment:special-operator-info :name function-name)))))

(defmethod cleavir-environment:optimize-info ((system sext-system) (env sb-kernel:lexenv))
  (make-instance 'cleavir-environment:optimize-info
                  :policy (cleavir-compilation-policy:compute-policy system nil)))

(defmethod cleavir-environment:declarations ((system sext-system) (env sb-kernel:lexenv))
  '())

(defmethod cleavir-environment:type-expand
    ((system sext-system) (env sb-kernel:lexenv) type-specifier)
  (sb-ext:typexpand type-specifier env))

;;; --- Portable-expansion overrides for "leaky" host macros -----------------
;;;
;;; See the file header for the full evidence trail. This allowlist is
;;; intentionally minimal: extend it only when a new BDD spec demonstrates
;;; a further failure (per project discipline -- no speculative coverage).

(defun %portable-defun-expander (form env)
  (declare (ignore env))
  (destructuring-bind (name lambda-list &body body) (rest form)
    (let ((block-name (if (consp name) (second name) name)))
      `(progn (setf (fdefinition ',name)
                    (lambda ,lambda-list (block ,block-name ,@body)))
              ',name))))

(defun %portable-defmacro-expander (form env)
  (declare (ignore env))
  (destructuring-bind (name lambda-list &body body) (rest form)
    `(progn (setf (macro-function ',name)
                  (lambda (%whole %env)
                    (declare (ignore %env))
                    (destructuring-bind ,lambda-list (rest %whole)
                      ,@body)))
            ',name)))

(defun %portable-when-expander (form env)
  (declare (ignore env))
  (destructuring-bind (test &body body) (rest form)
    `(if ,test (progn ,@body))))

(defun %portable-unless-expander (form env)
  (declare (ignore env))
  (destructuring-bind (test &body body) (rest form)
    `(if ,test nil (progn ,@body))))

(defmethod cleavir-environment:function-info :around
    ((system sext-system) (env sb-kernel:lexenv) function-name)
  (case function-name
    (cl:defun (make-instance 'cleavir-environment:global-macro-info
                              :name 'cl:defun :expander #'%portable-defun-expander))
    (cl:defmacro (make-instance 'cleavir-environment:global-macro-info
                                 :name 'cl:defmacro :expander #'%portable-defmacro-expander))
    (cl:when (make-instance 'cleavir-environment:global-macro-info
                             :name 'cl:when :expander #'%portable-when-expander))
    (cl:unless (make-instance 'cleavir-environment:global-macro-info
                               :name 'cl:unless :expander #'%portable-unless-expander))
    ;; LOOP: Khazern (s-expressionists/Khazern -- same org as Cleavir,
    ;; originally written for SICL) is a fully portable LOOP implementation
    ;; expanding to genuine ANSI special operators/macros only, and is the
    ;; correct pairing for a Cleavir-based tool, rather than SBCL's native
    ;; LOOP. NOTE: as of this writing, Khazern's own expansion still hits
    ;; the open INCF issue described in the file header -- DUMP-8 is not
    ;; yet green even with this override in place.
    (cl:loop (make-instance 'cleavir-environment:global-macro-info
                             :name 'cl:loop
                             :expander (macro-function 'khazern-extrinsic:loop)))
    (t (call-next-method))))

;;; --- EVAL / CST-EVAL -------------------------------------------------------
;;;
;;; cst-to-ast is run with *COMPILER* bound to CL:EVAL, not
;;; CL:COMPILE-FILE: COMPILE-FILE semantics pulls in SBCL-internal
;;; compile-time bookkeeping (SB-C:%COMPILER-DEFUN, requiring
;;; SB-C::*IR1-NAMESPACE* to be bound, which only a genuine COMPILE-FILE
;;; call sets up) that sext has no need for. With CL:EVAL semantics,
;;; genuine EVAL-WHEN :COMPILE-TOPLEVEL handling is bypassed entirely (per
;;; CLHS 3.2.3.1), so CST-EVAL is reached only for MACROLET/
;;; SYMBOL-MACROLET processing, never for per-top-level-form compile-time
;;; registration. For an intrinsic tool (host = target = this SBCL image,
;;; sext's case), CL:EVAL really is the correct implementation here -- same
;;; trust boundary as compiling the source would have anyway.

(defmethod cleavir-environment:eval (form environment (system sext-system))
  (declare (ignore environment))
  (cl:eval form))

(defmethod cleavir-environment:cst-eval (cst environment (system sext-system))
  (cleavir-environment:eval (concrete-syntax-tree:raw cst) environment system))

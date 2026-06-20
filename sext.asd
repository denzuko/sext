;;;; sext.asd
;;;;
;;;; sext -- dump Common Lisp source as a structured AST JSON object.
;;;; See CLAUDE.md for full design rationale before implementing.

(defsystem "sext"
  :description "Dump Common Lisp source as a structured AST JSON object, for piping into OPA/Rego, SARIF, and CycloneDX quality/security gates."
  :author "Dwight Spencer <denzuko@dapla.net>"
  :license "BSD-2-Clause"
  :version "0.0.1"
  :homepage "https://github.com/denzuko/sext"
  :depends-on (;; AST extraction. System names confirmed by direct
               ;; verification against the actual Cleavir/Eclector/
               ;; Concrete-Syntax-Tree source trees -- see CLAUDE.md,
               ;; "Issue #3 resolution" for the full evidence trail.
               ;; NOTE: cleavir-cst-to-ast, cleavir-ast, and the other
               ;; cleavir-* component systems are NOT on Quicklisp or
               ;; Ultralisp (confirmed: zero hits in either dist's
               ;; systems.txt) -- they ship only via git clone of the
               ;; single-repo Cleavir monorepo. See qlfile.
               "concrete-syntax-tree"
               "eclector-concrete-syntax-tree"
               "cleavir-cst-to-ast"
               "khazern-extrinsic"
               ;; CLOS-to-JSON: resolved (issue #4, see src/walker.lisp's
               ;; file header for the full evidence trail) -- neither
               ;; trivial-json-codec nor shasht is needed. The walker
               ;; fully flattens Cleavir's AST objects to plain data via
               ;; Cleavir's own CLEAVIR-IO:SAVE-INFO protocol; only a
               ;; thin plain-data JSON writer is needed for the output
               ;; side, and com.inuoe.jzon (already required for the
               ;; test suite's read side) covers that directly.
               "com.inuoe.jzon")
  :components
  ((:file "src/package")
   (:file "src/environment" :depends-on ("src/package"))
   (:file "src/walker"      :depends-on ("src/package" "src/environment"))
   (:file "src/serialize"   :depends-on ("src/package" "src/walker"))
   (:file "src/main"        :depends-on ("src/serialize")))
  :in-order-to ((test-op (test-op "sext/tests"))))

(defsystem "sext/tests"
  :description "FiveAM BDD spec suite for sext"
  :author "Dwight Spencer <denzuko@dapla.net>"
  :license "BSD-2-Clause"
  :version "0.0.1"
  :depends-on ("sext" "fiveam" "com.inuoe.jzon")
  :perform (test-op (op system)
    (declare (ignore op))
    (let ((cl-user::*sext-test-no-exit* t)
          (root (asdf:system-source-directory system)))
      (declare (special cl-user::*sext-test-no-exit*))
      (load (merge-pathnames "test/fiveam/test-sext.lisp" root)))))

(defsystem "sext/doc"
  :description "40ants-doc pages for sext"
  :author "Dwight Spencer <denzuko@dapla.net>"
  :license "BSD-2-Clause"
  :version "0.0.1"
  :depends-on ("sext" "40ants-doc")
  :components
  ((:file "docs/index")))

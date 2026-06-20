;;;; sext.asd
;;;;
;;;; sext -- dump Common Lisp source as a structured AST JSON object.
;;;; See CLAUDE.md for full design rationale before implementing.
;;;;
;;;; STATUS: skeleton only. src/*.lisp files are stubs raising
;;;; "not yet implemented" -- the next session's job is BDD-first
;;;; implementation against test/fiveam/test-sext.lisp.

(defsystem "sext"
  :description "Dump Common Lisp source as a structured AST JSON object, for piping into OPA/Rego, SARIF, and CycloneDX quality/security gates."
  :author "Dwight Spencer <denzuko@dapla.net>"
  :license "BSD-2-Clause"
  :version "0.0.1"
  :homepage "https://github.com/denzuko/sext"
  :depends-on (;; AST extraction -- confirm exact system names next session.
               ;; Likely: "concrete-syntax-tree", "cleavir-cst-to-ast"
               ;; or similar; Cleavir's system naming needs to be checked
               ;; directly against its .asd files before finalizing here.
               "concrete-syntax-tree"
               "cleavir-cst-to-ast"
               ;; CLOS-to-JSON -- decide between these two next session
               ;; (see CLAUDE.md open question), keep both as candidates
               ;; until one is proven to handle Cleavir AST classes:
               "trivial-json-codec"
               "com.inuoe.jzon")
  :components
  ((:file "src/package")
   (:file "src/walker"    :depends-on ("src/package"))
   (:file "src/serialize" :depends-on ("src/package" "src/walker"))
   (:file "src/main"      :depends-on ("src/serialize")))
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

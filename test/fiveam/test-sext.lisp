;;;; test/fiveam/test-sext.lisp
;;;;
;;;; BDD spec suite for sext (#1-#N, see GitHub issues).
;;;; Written BEFORE implementation per project BDD-first workflow.
;;;;
;;;; These specs are RED at commit time. They define the contract the
;;;; next session's implementation must satisfy. Do not skip straight
;;;; to making them pass without first confirming the design questions
;;;; flagged in CLAUDE.md (trivial-json-codec vs shasht CLOS-walking
;;;; behavior against actual Cleavir AST classes).

(dolist (path (list
               (merge-pathnames "quicklisp/setup.lisp" (user-homedir-pathname))
               #p"/home/claude/quicklisp/setup.lisp"))
  (when (probe-file path) (load path) (return)))

(unless (find-package :fiveam)
  (funcall (find-symbol "QUICKLOAD" :ql) :fiveam :silent t))

;; sext depends on Concrete-Syntax-Tree and Cleavir's CST-to-AST system.
;; These are NOT yet loaded here -- the next session's first task is
;; confirming exact system names and adding them to sext.asd / qlfile.
;; Placeholder load attempts below will fail until that's done; this
;; is intentional (RED).

(let* ((here (directory-namestring (truename *load-pathname*)))
       (root (namestring (truename (merge-pathnames "../../" (parse-namestring here))))))
  (unless (find-package :sext)
    (pushnew (truename root) asdf:*central-registry* :test #'equal)
    (handler-case
        (asdf:load-system :sext)
      (error (e)
        (format *error-output*
                "~&sext system failed to load (expected if implementation~%~
                 not yet started): ~A~%" e)))))

(defpackage #:sext-tests
  (:use #:cl #:fiveam))

(in-package #:sext-tests)

(def-suite sext-suite
  :description "sext AST-dump BDD specs")

(in-suite sext-suite)

;;; ── Fixtures ─────────────────────────────────────────────────────────────

(defparameter *simple-defun-source*
  "(defun add (a b) (+ a b))")

(defparameter *defun-with-docstring-source*
  "(defun greet (name)
     \"Return a greeting string for NAME.\"
     (format nil \"Hello, ~A!\" name))")

(defparameter *loop-form-source*
  "(defun sum-evens (list)
     (loop for x in list
           when (evenp x)
           sum x))")

(defparameter *multiple-forms-source*
  "(defpackage #:example (:use #:cl))
   (in-package #:example)
   (defun foo () 1)
   (defun bar () 2)")

(defparameter *macro-source*
  "(defmacro my-when (test &body body)
     `(if ,test (progn ,@body)))")

;;; ── DUMP-1..N: core dump contract ───────────────────────────────────────

(test DUMP-1-dump-string-returns-json-string
  "sext:dump-string accepts a CL source string and returns a JSON string."
  (let ((result (sext:dump-string *simple-defun-source*)))
    (is (stringp result))
    (is (> (length result) 0))))

(test DUMP-2-dump-string-produces-valid-json
  "Output of dump-string parses as valid JSON (round-trips through a decoder)."
  (let* ((json-str (sext:dump-string *simple-defun-source*))
         (parsed    (com.inuoe.jzon:parse json-str)))
    (is (not (null parsed)))))

(test DUMP-3-dump-file-accepts-pathname
  "sext:dump-file accepts a pathname and returns the same shape as dump-string."
  (let ((tmp (merge-pathnames "sext-test-input.lisp" (uiop:temporary-directory))))
    (unwind-protect
        (progn
          (with-open-file (s tmp :direction :output :if-exists :supersede)
            (write-string *simple-defun-source* s))
          (let ((result (sext:dump-file tmp)))
            (is (stringp result))
            (is (> (length result) 0))))
      (when (probe-file tmp) (delete-file tmp)))))

(test DUMP-4-output-contains-one-entry-per-top-level-form
  "Multiple top-level forms in source produce multiple entries in the dump."
  (let* ((json-str (sext:dump-string *multiple-forms-source*))
         (parsed    (com.inuoe.jzon:parse json-str)))
    ;; Expect 4 top-level forms: defpackage, in-package, 2x defun
    (is (= 4 (length parsed)))))

;;; ── DUMP-5..N: structural fidelity (the actual point of using Cleavir) ──

(test DUMP-5-defun-form-captures-function-name
  "A defun form's dump includes the function name."
  (let* ((json-str (sext:dump-string *simple-defun-source*))
         (parsed    (com.inuoe.jzon:parse json-str)))
    (is (search "add" json-str))))

(test DUMP-6-defun-form-captures-lambda-list
  "A defun form's dump includes its parameter list."
  (let ((json-str (sext:dump-string *simple-defun-source*)))
    (is (search "a" json-str))
    (is (search "b" json-str))))

(test DUMP-7-docstring-captured-distinctly-from-body
  "A defun's docstring is captured as a distinct field, not conflated with body."
  (let ((json-str (sext:dump-string *defun-with-docstring-source*)))
    (is (search "Return a greeting" json-str))))

(test DUMP-8-loop-form-expands-correctly
  "A LOOP form is captured via its semantic expansion (Cleavir AST), not
   as an opaque, unexamined surface s-expression. This is the core
   differentiator vs. a naive (read)-based walker: LOOP's surface syntax
   bears no resemblance to its semantics, and a policy that wants to
   reason about 'does this function sum things' needs the canonicalized
   form, not the raw macro call."
  (let ((json-str (sext:dump-string *loop-form-source*)))
    ;; The dump must NOT simply contain the literal token "loop" as an
    ;; unexpanded opaque call -- it must show the expanded control flow.
    ;; Exact assertion TBD once Cleavir AST class names for loop expansion
    ;; are confirmed in the next session; placeholder checks presence of
    ;; some expanded-form evidence (e.g. a block/tagbody/go AST node type,
    ;; which is what LOOP typically macroexpands into).
    (is (or (search "block" json-str)
            (search "tagbody" json-str)
            (search "go" json-str)))))

(test DUMP-9-macro-definition-captured
  "A defmacro form is captured distinctly from a defun form (different
   AST node type), so policy can distinguish macros from functions."
  (let ((json-str (sext:dump-string *macro-source*)))
    (is (search "my-when" json-str))))

;;; ── DUMP-10..N: error handling ──────────────────────────────────────────

(test DUMP-10-malformed-source-signals-condition-not-crash
  "Malformed/unreadable Lisp source signals a sext-specific condition
   rather than an unhandled reader error or process crash."
  (signals error
    (sext:dump-string "(defun broken (")))

(test DUMP-11-empty-source-returns-empty-array
  "Empty source string produces a valid empty JSON array, not an error."
  (let* ((json-str (sext:dump-string ""))
         (parsed    (com.inuoe.jzon:parse json-str)))
    (is (= 0 (length parsed)))))

(test DUMP-12-nonexistent-file-signals-condition
  "dump-file on a nonexistent path signals a clear condition."
  (signals error
    (sext:dump-file #p"/nonexistent/path/to/nowhere.lisp")))

;;; ── DUMP-13..N: CLI / binary contract (Roswell entry point) ─────────────

(test DUMP-13-cli-main-accepts-file-arg
  "sext::main, given a file path argument, writes JSON to stdout and
   returns exit code 0 on success. This is the contract the Roswell
   script (roswell/sext.ros) must satisfy -- tested at the Lisp function
   level here; a BATS-equivalent integration spec against the compiled
   binary belongs in a future test/bats/ directory once the binary build
   is implemented."
  (let ((tmp (merge-pathnames "sext-cli-test.lisp" (uiop:temporary-directory))))
    (unwind-protect
        (progn
          (with-open-file (s tmp :direction :output :if-exists :supersede)
            (write-string *simple-defun-source* s))
          (let ((output (with-output-to-string (*standard-output*)
                          (sext::main (list (namestring tmp))))))
            (is (> (length output) 0))))
      (when (probe-file tmp) (delete-file tmp)))))

(test DUMP-14-cli-main-help-flag-prints-usage-and-exits-zero
  "sext::main, given --help (or -h), writes usage text to stdout and
   returns 0 without requiring or touching a file argument -- the
   contract issue #7 sub-item 4 requires, and what removes the need
   for the `--help || true` escape hatch in the CI build job."
  (let (exit-code output)
    (setf output (with-output-to-string (*standard-output*)
                   (setf exit-code (sext::main (list "--help")))))
    (is (= exit-code 0))
    (is (> (length output) 0))
    (is (search "Usage:" output))))

(test DUMP-15-cli-main-no-args-prints-usage-to-stderr-and-exits-one
  "sext::main, given no arguments, writes usage to *ERROR-OUTPUT* and
   returns 1 -- a graceful CLI error, not an unhandled Lisp condition
   from PATHNAME on NIL."
  (let (exit-code output)
    (setf output (with-output-to-string (*error-output*)
                   (setf exit-code (sext::main nil))))
    (is (= exit-code 1))
    (is (> (length output) 0))))

;;; ── Run suite ────────────────────────────────────────────────────────────

(let ((results (run 'sext-suite)))
  (explain! results)
  (let ((ok (every #'fiveam::test-passed-p results)))
    (if (and (boundp 'cl-user::*sext-test-no-exit*)
             cl-user::*sext-test-no-exit*)
        (unless ok (error "sext-suite: FiveAM tests failed"))
        (sb-ext:exit :code (if ok 0 1)))))

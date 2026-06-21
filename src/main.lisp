;;;; src/main.lisp -- public API and CLI entry point

(in-package #:sext)

(defun %cst-to-ast (cst)
  "Convert one already-read CST into a Cleavir AST node, using sext's
own environment bridge (src/environment.lisp). *COMPILER* is bound to
CL:EVAL (not CL:COMPILE-FILE) for the reasons documented in
environment.lisp's \"EVAL / CST-EVAL\" section: COMPILE-FILE semantics
pulls in SBCL-internal compile-time bookkeeping sext has no need for.
SB-KERNEL:MAKE-NULL-LEXENV is SBCL-specific, consistent with the rest
of this bridge (already deeply SBCL-coupled throughout
src/environment.lisp; sext does not currently aim for portability
across CL implementations)."
  (let ((cleavir-cst-to-ast:*compiler* 'cl:eval))
    (cleavir-cst-to-ast:cst-to-ast cst (sb-kernel:make-null-lexenv) *system*)))

(defun %dump-forms-to-asts (source)
  "Read and convert each top-level form in SOURCE to a Cleavir AST node,
in order, interleaving read and convert one form at a time (rather than
reading everything up front) so that a compile-time side effect from an
earlier top-level form -- most commonly IN-PACKAGE -- is visible when
reading later ones, matching ordinary CL:LOAD semantics. Returns the
empty list for empty/all-whitespace SOURCE (DUMP-11's contract)."
  (with-input-from-string (stream source)
    (loop for cst = (eclector.concrete-syntax-tree:read stream nil :eof)
          until (eq cst :eof)
          collect (%cst-to-ast cst))))

(defun dump-string (source)
  "Parse SOURCE (a Common Lisp source string) via Concrete-Syntax-Tree +
Cleavir CST-to-AST, walk the resulting AST(s), and return a JSON string:
a JSON array with one entry per top-level form in SOURCE (the empty
array for empty/all-whitespace SOURCE). Wraps any error encountered
while reading or converting SOURCE -- malformed/unreadable Lisp source,
a Cleavir NO-FUNCTION-INFO error for a call to an unresolvable function
(see issue #14), or anything else -- in SEXT-PARSE-ERROR, rather than
letting a raw reader condition or Cleavir condition escape. Unlike an
earlier version of this function, the real underlying condition is
preserved (SEXT-PARSE-ERROR-CAUSE) and included in the report, not
discarded -- a bare \"failed to parse source\" with no indication of
*why* gave callers no way to distinguish a genuine syntax error from
issue #14's limitation from anything else without re-deriving it
themselves."
  (handler-case
      (serialize-to-json (walk-top-level-forms (%dump-forms-to-asts source)))
    (sext-error (e) (error e))
    (error (e)
      (error 'sext-parse-error :source source :cause e))))

(defun dump-file (path)
  "Read and dump the Common Lisp source file at PATH (a pathname).
Signals SEXT-FILE-ERROR if PATH does not exist; otherwise behaves
exactly like DUMP-STRING on the file's contents."
  (let ((path (pathname path)))
    (unless (probe-file path)
      (error 'sext-file-error :path path))
    (dump-string (uiop:read-file-string path))))

(defparameter *usage*
  "sext -- dumps Common Lisp source as a JSON AST via Cleavir CST-to-AST,
for OPA/Rego/SARIF/CycloneDX tooling.

Usage:
  sext <path-to-lisp-file>   Dump PATH's JSON AST to stdout
  sext --help, -h            Show this message

Output: a JSON array with one entry per top-level form in the file.
")

(defun main (args)
  "CLI entry point. ARGS is a list of command-line argument strings.
With a single file-path argument, writes the JSON dump of that file to
*STANDARD-OUTPUT* and returns 0 on success; on a SEXT-ERROR, writes a
message to *ERROR-OUTPUT* and returns 1. With --help/-h (in any
position, not just first -- a common CLI convention: --help should
work even after other flags), writes usage to *STANDARD-OUTPUT* and
returns 0 without requiring a file argument. With no arguments at all,
writes usage to *ERROR-OUTPUT* (it's the error case: a file argument
was expected and not given) and returns 1, rather than signalling an
unhandled Lisp error from PATHNAME on NIL. This is the function the
Roswell script (roswell/sext.ros, issue #7) calls."
  (cond
    ((member "--help" args :test #'string=) (write-string *usage*) 0)
    ((member "-h" args :test #'string=) (write-string *usage*) 0)
    ((null args) (write-string *usage* *error-output*) 1)
    (t (handler-case
           (let ((path (first args)))
             (write-string (dump-file (pathname path)))
             (terpri)
             0)
         (sext-error (e)
           (format *error-output* "~A~%" e)
           1)))))

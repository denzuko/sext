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
most commonly -- in SEXT-PARSE-ERROR, rather than letting a raw reader
condition or Cleavir condition escape."
  (handler-case
      (serialize-to-json (walk-top-level-forms (%dump-forms-to-asts source)))
    (sext-error (e) (error e))
    (error (e)
      (declare (ignore e))
      (error 'sext-parse-error :source source))))

(defun dump-file (path)
  "Read and dump the Common Lisp source file at PATH (a pathname).
Signals SEXT-FILE-ERROR if PATH does not exist; otherwise behaves
exactly like DUMP-STRING on the file's contents."
  (let ((path (pathname path)))
    (unless (probe-file path)
      (error 'sext-file-error :path path))
    (dump-string (uiop:read-file-string path))))

(defun main (args)
  "CLI entry point. ARGS is a list of command-line argument strings
(currently just a single file path). Writes the JSON dump of that file
to *STANDARD-OUTPUT* and returns 0 on success; on a SEXT-ERROR, writes
a message to *ERROR-OUTPUT* and returns 1. This is the function the
Roswell script (roswell/sext.ros, issue #7) calls."
  (handler-case
      (let ((path (first args)))
        (write-string (dump-file (pathname path)))
        (terpri)
        0)
    (sext-error (e)
      (format *error-output* "~A~%" e)
      1)))

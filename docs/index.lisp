;;;; docs/index.lisp -- 40ants-doc pages for sext
;;;;
;;;; Loaded via the "sext/doc" ASDF system (sext.asd). Build HTML docs
;;;; with, e.g.:
;;;;   (asdf:load-system :sext/doc)
;;;;   (40ants-doc-full/builder:render-to-files sext::@sext-manual
;;;;                                            :output "docs/build/")
;;;; (40ants-doc-full, not plain 40ants-doc, is needed to actually
;;;; render to HTML/Markdown files -- 40ants-doc/core alone only
;;;; defines DEFSECTION and the cross-reference machinery this file
;;;; uses; see 40ants-doc.asd's own dependency split.)

(in-package #:sext)

(40ants-doc:defsection @sext-manual (:title "sext")
  "S-EXpression Tree -- dump Common Lisp source as a structured AST
JSON object, for piping into OPA/Rego policy gates, SARIF
static-analysis tooling, and CycloneDX SBOM generation.

```
source.lisp -> Concrete-Syntax-Tree -> Cleavir CST-to-AST -> sext -> JSON -> Rego/SARIF/CycloneDX
```

See the [JSON schema](https://github.com/denzuko/sext/blob/develop/docs/schema.md)
for the exact output shape this produces, and
[`policy/examples/`](https://github.com/denzuko/sext/tree/develop/policy/examples)
for a complete, `opa test`-verified example policy written against it.

Known limitation: every function called by the source being dumped
must be a standard/built-in Common Lisp function or already loaded
into the running image -- a function merely defined elsewhere in the
same project, even earlier in the same file, does not yet resolve
(see issue [#14](https://github.com/denzuko/sext/issues/14))."
  (@sext-api section))

(40ants-doc:defsection @sext-api (:title "API")
  "The two functions below are sext's whole public dump API; MAIN is
the CLI entry point the Roswell script (roswell/sext.ros) calls, and
isn't generally called directly from other Lisp code."
  (dump-string function)
  (dump-file function)
  (main function)
  (sext-error condition)
  (sext-parse-error condition)
  (sext-file-error condition))

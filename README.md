# sext

**S-EXpression Tree** — dump Common Lisp source as a structured AST
JSON object, for piping into OPA/Rego policy gates, SARIF static-analysis
tooling, and CycloneDX SBOM generation.

> **Status: pre-implementation.** This repository currently contains a
> BDD-first specification (FiveAM test suite), architecture documentation,
> and a stubbed ASDF system. See `CLAUDE.md` for full design rationale
> and `docs/pipeline.mmd` for the architecture diagram. Implementation
> has not yet started — see open issues.

## What this is

The C/C99 ecosystem has `clang -ast-dump=json` as a mature, standard
way to extract a structured AST from source for downstream policy
tooling. Common Lisp has no equivalent. `sext` closes that specific
gap — nothing more.

```
source.lisp → Concrete-Syntax-Tree → Cleavir CST-to-AST → sext → JSON → Rego/SARIF/CycloneDX
```

`sext` does exactly one thing: produce a complete, faithful JSON
serialization of a Common Lisp AST. It has no opinion on what counts
as a policy violation — that's Rego's `walk()` builtin and your own
`.rego` files, evaluated downstream, not `sext`'s job.

## Why not just `(read)` the source?

Lisp's homoiconicity means `(read)` does give you "an AST" in a
trivial sense — but it gives you *surface syntax*, not *semantics*.
A `loop` form's surface s-expression bears no resemblance to what it
actually does. Catching real structural bugs (the kind unit tests
miss) requires the canonicalized, macro-expanded form, which is
exactly what [Cleavir](https://github.com/s-expressionists/Cleavir)'s
`CST-to-AST` system already does correctly, via the standard CLtL2
environment protocol.

## Why not build on CLAST?

[CLAST](https://clast.sourceforge.net/) is purpose-built for this
exact problem but has been dormant since ~2017 with a single original
maintainer. `sext` builds on Cleavir instead: actively maintained,
BSD-2-Clause, org-owned, and the AST layer underlying real CL compiler
projects like SICL.

## Installation (once implemented)

```sh
ros install denzuko/sext
sext path/to/source.lisp
```

Or via Quicklisp/ASDF:

```lisp
(ql:quickload :sext)
(sext:dump-file #p"path/to/source.lisp")
```

## Scope boundary

`sext` ships example/reference policies (`policy/examples/`) to prove
the JSON schema is usable — these are **not** production policy for
any organization. Real policy content belongs in separate,
organization-owned repos that depend on `sext` as a tool.

## License

BSD-2-Clause.

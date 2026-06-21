# sext

**S-EXpression Tree** — dump Common Lisp source as a structured AST
JSON object, for piping into OPA/Rego policy gates, SARIF static-analysis
tooling, and CycloneDX SBOM generation.

> **Status: working, pre-1.0.** `dump-string`/`dump-file`/the CLI are
> implemented and BDD-tested (see `test/fiveam/`), and `ros build
> roswell/sext.ros` produces a working standalone binary. See
> `docs/schema.md` for the JSON output schema and `CLAUDE.md` for full
> design rationale. Known limitation: `sext` can currently only dump
> source where every called function is a standard/built-in CL
> function or already loaded into the running image -- not a function
> merely defined elsewhere in the same project (see issue #14).
> `ros install denzuko/sext` isn't set up yet (needs a tagged release).

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
`.rego` files, evaluated downstream, not `sext`'s job. See
`docs/schema.md` for the exact JSON shape, and `policy/examples/` for
a complete, `opa test`-verified example policy written against it.

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

## Installation

Via Quicklisp/ASDF, and (once a `qlot install` is run against this
repo's `qlfile`, since Cleavir isn't on Quicklisp/Ultralisp) `ros
build`:

```lisp
(ql:quickload :sext)
(sext:dump-file #p"path/to/source.lisp")
```

```sh
qlot install
qlot exec ros build roswell/sext.ros
./roswell/sext path/to/source.lisp
```

`ros install denzuko/sext` (a one-line install for end users, no local
clone needed) isn't available yet -- it needs a tagged release first.

## Use in CI

Two GitHub Actions, meant to be used together:
[`denzuko/setup-sext`](https://github.com/denzuko/setup-sext) installs
the `sext` binary (building from source, since there's no tagged
release yet); the `denzuko/sext` action (`action.yml` at this repo's
root) then runs it against a file or a whole directory and writes
combined JSON output.

```yaml
- uses: denzuko/setup-sext@main
- uses: denzuko/sext@develop
  with:
    source: ./src
    output: ast-output.json
- run: opa eval -i ast-output.json -d ./policy "data.main.deny" --fail-defined
```

See `docs/schema.md`'s last section for the action's combined output
shape (one entry per file, distinct from the binary's own per-file
schema documented above it), and the `denzuko/sext#14` limitation
note above -- it affects how much of a real multi-file `source`
directory will dump cleanly today.

## Scope boundary

`sext` ships example/reference policies (`policy/examples/`) to prove
the JSON schema is usable — these are **not** production policy for
any organization. Real policy content belongs in separate,
organization-owned repos that depend on `sext` as a tool.

## License

BSD-2-Clause.

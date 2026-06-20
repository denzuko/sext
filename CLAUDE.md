# CLAUDE.md — sext Project Internal Knowledge

This file records architectural decisions and context from the design
session that produced this repository. Read this before writing any code.

---

## What sext is

**sext** (S-EXpression Tree) dumps Common Lisp source as a structured
AST JSON object, for piping into existing, established quality and
security tooling: OPA/Rego policy gates, SARIF static-analysis output,
CycloneDX SBOM generation, and VEX vulnerability-exploitability
attestations.

sext is the missing piece in the Common Lisp tooling ecosystem that
the C/C99 world already has solved via `clang -ast-dump=json`. It is
**not** a linter, a style checker, or a compiler. It does exactly one
thing: produce a faithful, complete, JSON-serialised AST of CL source,
so policy engines downstream can ask their own questions of it.

## Why this exists (origin context)

Built following an extended session hardening `mlisp` (a Common Lisp
mailing list manager, github.com/denzuko/mlisp) where several rounds
of architectural review surfaced real but localized defects: duplicate
RFC 5322 header-parsing logic across two files, a filter-pipeline bug
where configured shell commands with arguments were silently
space-split and broken, a hanging TODO left alongside an unused DSL,
and ~50 lines of dead orphaned code from an incomplete prior edit that
human review caught but BDD/unit/e2e tests did not, because those
tests validate *behavior*, not *structure*.

The C99/kcgi-derived projects (podcast-mgr, others) already solve this
class of problem: dump the AST via `clang -ast-dump=json`, filter with
a jq projection (see `nob_ast_filter.jq` in that prior art), evaluate
structural invariants in Rego (`policy/nob_ast.rego`, `policy/sarif.rego`),
gate the build. Common Lisp has no equivalent of `clang -ast-dump=json`.
sext is the tool that closes that specific gap — nothing more.

## Core design decision: dump everything, let Rego filter

Early design considered having the dump tool itself perform projection
(deciding which forms/symbols matter, analogous to what the jq filter
did for C). **This was rejected.** Rego's `walk()` builtin can traverse
an arbitrary nested JSON tree exactly like jq's recursive descent —
there is no need for a configurable projection layer in sext itself.

sext therefore does ONE thing: walk the AST and emit a complete,
faithful JSON representation of every top-level form. It has no
concept of what a "policy violation" is and never will. All filtering,
projection, and policy logic belongs in consuming repos' `.rego` files,
not in sext.

This also means sext's output format never needs to change to support
a new policy — new policies are just new Rego files written against
the existing complete dump.

## Technical foundation: standing on existing shoulders

After explicit research into the Common Lisp ecosystem (not assumed,
verified via web search against fukamachi's and 40ants' actual tooling
and current GitHub activity), the following stack was chosen:

### AST extraction: Cleavir CST-to-AST, NOT a hand-rolled reader-walker

- **Considered and rejected: CLAST** (github.com/olewhalehunter/clast,
  also at clast.sourceforge.net). Purpose-built for exactly this
  ("produce an AST of a CL form"), but dormant since ~2017, single
  original maintainer, author's own description called it "still in
  fieri" (in progress) with no subsequent activity. Building new public
  infrastructure on a dead single-maintainer library is a maintenance
  risk this project should not inherit.

- **Chosen: Cleavir** (github.com/s-expressionists/Cleavir). BSD-2-Clause,
  actively maintained (org-owned by `s-expressionists`, 5,844+ commits,
  v2.0.0 tagged Nov 2022, ongoing activity), used as the AST/compiler
  framework underlying SICL and other serious CL compiler-construction
  efforts. Critically, Cleavir is explicitly modular — its own README
  states "a code-walking application need not use anything below the
  AST level," meaning consuming only the `CST-to-AST` system (plus its
  dependency `Concrete-Syntax-Tree`) does not pull in the full compiler
  pipeline (BIR generation, optimization passes, register allocation).

- The pipeline: **Concrete-Syntax-Tree** (parses source, preserving
  original source-location info) → **Cleavir CST-to-AST** (canonicalizes
  into typed `standard-object` AST node classes, correctly expanding
  `loop` and other macro-heavy forms via the standard CLtL2 environment
  protocol — this is the exact case where a naive `(read)`-based walker
  fails, since surface s-expressions diverge from semantic structure
  for macros) → **sext's actual new code: a thin walker that serializes
  the Cleavir AST class hierarchy to JSON.**

- Rejected: a hand-rolled `(read)`-based form walker. While Lisp's
  homoiconicity means `(read)` does give you "the AST" in a trivial
  sense (source IS s-expressions), this does not handle macroexpansion
  (a `loop` form's surface syntax bears no resemblance to what it
  actually does), which is exactly the class of bug this tool exists
  to catch. Cleavir solves this correctly already.

### JSON serialization: existing CLOS-aware encoders, NOT hand-written

Cleavir's AST nodes are CLOS `standard-object` instances. Plain JSON
encoders (jzon, the modern community consensus pick for raw JSON
read/write — RFC 8259 correct, distinguishes null/false/empty-array
properly, on Quicklisp+Ultralisp) do not know how to walk a CLOS slot
graph by default.

- **Primary candidates for the CLOS→JSON layer** (verified via search,
  not assumed): `trivial-json-codec` (explicitly supports encoding
  CLOS objects, structures, and hash-tables; works with multiple JSON
  backends including jzon/shasht) and `shasht` (also explicitly
  CLOS-aware, fast, correct null-handling, on Quicklisp).
- `herodotus` was considered and set aside: its model is "define a
  CLOS class and its JSON serializer together via a macro," which fits
  greenfield class definitions, not retrofitting serialization onto
  classes sext does not own (Cleavir's AST classes).
- **Open question for the next session**: verify whether
  `trivial-json-codec`'s or `shasht`'s default CLOS-walking behavior
  handles Cleavir's actual AST class definitions out of the box, or
  whether per-class slot configuration is needed. Check Cleavir's
  `Abstract-syntax-tree/` directory class definitions directly before
  assuming "it just works."

### Distribution: 40ants pattern, not cookiecutter

`cl-cookieproject` (vindarel) was reviewed for project-scaffolding
conventions but rejected as the literal scaffold tool because it
requires Python/cookiecutter as a templating dependency — an odd
mismatch for a pure-CL tool. Its own README directs to better-fitting
alternatives for this use case; **40ants/project-templates** was
selected as the structural reference (Quicklisp + Ultralisp + Qlot +
CLPM, Rove/FiveAM tests, GitHub CI, 40ants-doc-based documentation) —
same vendor and toolchain already proven via `40ants/setup-lisp` and
`40ants/run-tests` actions used in the mlisp project, and the same
`40ants-ci/jobs/linter` (wraps sblint) and `40ants-ci/jobs/critic`
(wraps lisp-critic) job types that are the actual community-standard
adjacent tools for CL static analysis.

sext follows the 40ants distribution model exactly: a Roswell script
as the canonical entry point, compiled to a standalone binary via
`ros build`, distributed three ways — Quicklisp-installable ASDF
system, standalone Roswell-installable binary (`ros install
denzuko/sext`), and a `denzuko/setup-sext`-style GitHub Action mirroring
`40ants/setup-lisp`'s UX. Matching this install UX is necessary, not
optional — a tool requiring `git clone` + manual ASDF load does not
compete with `ros install fukamachi/sblint`'s one-liner, and adoption
outside this project depends on matching that bar.

## What "community standard" already covers (do not rebuild)

Verified via direct research, not assumed:

- **sblint** (fukamachi) — per-file SBCL compiler `STYLE-WARNING`
  surfacing in Reviewdog-compatible format. Catches unused local
  variables, not cross-file dead `defun`s (SBCL does not do this by
  design, since exported symbols are assumed to have external
  consumers). Already wired into `40ants-ci/jobs/linter`.
- **lisp-critic** — idiom/style/logical-error advisor. Already wired
  into `40ants-ci/jobs/critic`.
- **cdxgen** — language-agnostic SBOM generation (dependency-graph
  based, works on any project regardless of language since it reads
  package manifests, not source ASTs). No CL-specific work needed.
- **OPA/Rego, SARIF, VEX** — all language-agnostic formats/tools
  already. No CL-specific work needed; sext's JSON output is simply
  one more input source they can consume.

**The only genuine gap was: there is no tool that dumps a complete,
structurally faithful Common Lisp AST as JSON.** That is sext's entire
scope. Resist any temptation to expand scope into linting, style
checking, or policy evaluation — those are solved problems or belong
in consuming repos' Rego files, not here.

## Convention: exported symbols ARE the public API boundary

Confirmed as standard CL community convention (Gigamonkeys/Practical
Common Lisp, multiple independent sources): a package's exported
symbol list is the documented, intentional public API surface.
Internal (unexported) symbols are implementation detail.

Any future policy work in *consuming* repos (not sext itself, which
has no opinion on this) that wants to flag "unused" symbols should
treat exported symbols as exempt from dead-code flagging by default —
an exported-but-not-internally-called symbol is not a defect, it is
the intended shape of a library API. This was confirmed against actual
40ants-doc behavior (exported symbols are what get documented; internal
symbols are explicitly excludable, not silently swept) and is the
correct default for any Rego policy a consuming repo writes against
sext's output.

## Ownership and licensing model

- **sext itself**: public tool, denzuko org, BSD-2-Clause (matching
  Cleavir's license for consistency, and the general CL ecosystem
  license norm — verify against `mlisp`'s own license choice before
  finalizing). Promoted/documented via dwightaspencer.com content in
  practitioner voice — no DPS or RT4 branding (entity separation rule
  carried over from the mlisp/dwightaspencer.com project).
- **Policy content** (actual `.rego` files encoding a specific
  organization's quality bar, e.g. DPS's standards) is explicitly
  OUT OF SCOPE for this repo. sext ships example/reference policies
  only, to prove the JSON schema is usable — not production policy.
  Real policy repos depend on sext as a tool, the same way podcast-mgr
  depends on `clang`/`opa`/`cdxgen` without those tools containing
  podcast-mgr's actual policy.

## Architecture diagram

See `docs/pipeline.mmd` for the Mermaid flowchart of the full pipeline:
source → Concrete-Syntax-Tree → Cleavir CST-to-AST → sext serializer →
JSON → (Rego | SARIF tooling | CycloneDX | VEX) → gate decision.

## Workflow rules (carried over from mlisp project conventions)

- BDD-first: FiveAM specs written before implementation, always.
- Feature branches → PR → `develop`, never direct commits.
- Never merge without explicit approval.
- Semver: MAJOR=public API break only, MINOR=new capability,
  PATCH=everything else.
- No hanging TODOs: every `; TODO`/`; future:` comment must be either
  resolved or converted into a tracked GitHub issue before merge —
  this exact failure mode (an ignored `extra-bindings` parameter with
  a stale "future: token substitution" comment) is what prompted part
  of the mlisp review that led to this project existing.

## Issue #3 resolution (2026-06-20)

Resolved by direct, empirical verification: cloned Cleavir, installed a
real SBCL + Quicklisp, and actually loaded/exercised the pipeline rather
than reading docs alone. Full findings below; this also substantially
de-risks issues #4 and #5, which is why the writeup goes beyond "the
system names are X."

**System names and sourcing** (now reflected in `sext.asd`/`qlfile`):

- `concrete-syntax-tree`, `eclector`, `eclector-concrete-syntax-tree`,
  `khazern`, `khazern-extrinsic`, `ctype`, `ctype/tfun`,
  `trivial-json-codec`, `com.inuoe.jzon`, `shasht`, `fiveam`,
  `closer-mop`, `40ants-doc`, `40ants-ci` — all present in the default
  Quicklisp dist (2026-01-01). No Ultralisp needed for any of these.
- `cleavir-cst-to-ast` (and every other `cleavir-*` system) is **not**
  on Quicklisp or Ultralisp — confirmed zero matches in either dist's
  systems.txt/releases.txt. Cleavir ships only as a single monorepo at
  `github.com/s-expressionists/Cleavir` (it used to be split across
  several repos; CLAUDE.md's original assumption of a separate `AST/`
  repo etc. was wrong). Every subdirectory containing a `.asd` needs to
  be pushed onto the ASDF registry, not just the repo root.
- Previously unflagged gap: Concrete-Syntax-Tree itself does not read
  text into CSTs — that's `eclector-concrete-syntax-tree`
  (`eclector.concrete-syntax-tree:read-from-string`), a separate system.

**A live-SBCL `cleavir-environment` bridge is required and was not
anticipated by the original design.** `cleavir-cst-to-ast:cst-to-ast`
needs an environment object satisfying the full `cleavir-environment`
generic-function protocol (variable-info, function-info, optimize-info,
declarations, type-expand, eval, cst-eval) — there is no default/no-op
implementation. Cleavir's own shipped example bridges
(`Environment/Examples/{hostile,sbcl}.lisp`) are written against an
older version of this protocol and do not load as-is (e.g.
`optimize-info` used to take 1 argument, now takes 2). sext owns a
current, from-scratch bridge at `src/environment.lisp`, built on
`sb-cltl2`, verified by direct testing.

**A `cleavir-ctype` ↔ `ctype` glue layer is also required.**
`cleavir-ctype` is an abstract protocol with no default implementation;
a concrete type representation must be supplied. `ctype`/`ctype/tfun`
(a separate library by the same org, on Quicklisp) is the concrete
backend Cleavir's own `Example/` frontend uses, and is what
`src/environment.lisp` now wires in. Without this, converting *any*
ordinary function call (e.g. `(+ a b)`) fails inside
`CLEAVIR-CST-TO-AST::MAKE-CALL`. sext only needs an "unconstrained
function of anything" ctype to avoid crashing — no real type
inference — which is what's implemented.

**Structural risk, confirmed by direct testing (not theoretical):**
several of SBCL's own standard-macro implementations call private
`SB-C` internals directly on whatever environment object their
expander function receives, instead of going through the portable
`SB-CLTL2` API. This breaks when the environment is one of
`cleavir-environment`'s augmentation-chain objects (`TAG`, `BLOCK`,
`VARIABLE-TYPE`, etc.) rather than a genuine `SB-KERNEL:LEXENV`.
Confirmed instances:
- `CL:DEFUN`/`CL:DEFMACRO` expand via `SB-INT:NAMED-LAMBDA`, which
  Cleavir's `FUNCTION` special-form converter correctly rejects (not
  ANSI-specified). **Workaround applied**: portable expanders in
  `src/environment.lisp` bypass SBCL's macro entirely for these two.
- `CL:WHEN`/`CL:UNLESS`, when their body is a single `(GO tag)` form
  (exactly LOOP's end-of-list-test shape) — SBCL's "prognify"
  optimization calls `SB-C::%COERCE-TO-POLICY` on the env argument.
  **Workaround applied**: same pattern, portable expanders.
- `CL:LOOP` itself, independently. **Workaround applied**: delegate to
  Khazern (`s-expressionists/Khazern`, same org as Cleavir, originally
  written for SICL, currently used by SICL and Clasp for exactly this
  reason) instead of SBCL's native LOOP.
- **Still open, not yet fixed**: Khazern's own portable expansion is
  clean (verified: only BLOCK/LET*/LABELS/TAGBODY/GO/WHEN/COND/
  RETURN-FROM, no SBCL internals — confirmed by direct macroexpansion
  inspection) but its accumulator update uses `CL:INCF`, and sext's own
  portable DEFMACRO expander uses `CL:DESTRUCTURING-BIND` — both
  standard *macros* (not special operators), both observed to fail the
  same class of error when expanded through this bridge. This means
  **DUMP-8 (LOOP) and DUMP-9 (DEFMACRO) are not yet green**, even with
  every fix above applied. Two candidate directions for issue #5:
  (a) keep extending the portable-override allowlist one macro at a
  time as BDD specs surface each failure (consistent with project
  discipline, but plausibly whack-a-mole — the set of "leaky" SBCL
  macros isn't yet known to be finite/enumerable), or
  (b) adopt a portable standard-macro layer wholesale (same category of
  project as Khazern, but for SETF/INCF/DECF/DESTRUCTURING-BIND/etc.)
  instead of bridging to SBCL's native versions of these at all, and
  reserve the live-SBCL bridge for genuinely user-defined macros and
  true unknowns only. **This decision should be made explicitly at the
  start of issue #5**, not implicitly by whichever fix compiles first.

**Verified working** (direct testing, real SBCL, real Cleavir, through
the actual `sext` ASDF system — not just a throwaway script): simple
`defun`, `defun` with a docstring, multiple independent top-level
forms (e.g. `defpackage`) processed one at a time. **Verified still
failing**: LOOP-wrapped-in-defun (DUMP-8), defmacro (DUMP-9) — both for
the INCF/DESTRUCTURING-BIND reason above. `dump-string`'s empty-string
handling (DUMP-11) also not yet addressed — Eclector signals EOF on an
empty string by default; needs explicit `:eof-error-p nil` handling.
That's issue #6 territory, noted here only because it surfaced during
verification.

**Landed in this branch**: `sext.asd` and `qlfile` updated with the
confirmed dependency list above; `src/environment.lisp` added (the
verified bridge + ctype glue + portable-macro overrides, ~230 lines,
fully documented inline with the same evidence trail as this section).
`src/walker.lisp`, `src/serialize.lisp`, `src/main.lisp` are
untouched — still stubs. Issue #5 (walk-ast) is next, and should start
by resolving the open LOOP/DEFMACRO question above before writing the
walker itself, since the answer changes how much of the walker needs
to special-case "leaky" macro shapes versus trusting the AST it's
handed.

**Environment limitation**: this work was done in a sandboxed container
with no GitHub credentials (no `gh` CLI, no `GH_TOKEN`, push over HTTPS
fails with no way to authenticate). All work above is committed locally
on the `issue-3-confirm-cleavir-systems` branch (off `develop`, off
`main`) but has not been pushed or opened as a PR — that needs to
happen from an environment with real GitHub access.


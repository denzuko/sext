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
untouched — still stubs.

**Push/PR**: this work was committed and pushed via a short-lived,
project-scoped GitHub PAT supplied by the project owner, and opened as
**PR #9** (`issue-3-confirm-cleavir-systems` → `develop`) for review.
Not merged — per project workflow rules, merging only happens on
explicit "ok do it" from the owner.

## Issue #5 notes (2026-06-20)

Issue #3's PR flagged an open question: Khazern's own LOOP expansion,
and sext's own portable DEFMACRO expander, both transitively use
standard macros (`CL:INCF`, `CL:DESTRUCTURING-BIND`) that turned out to
hit the same SBCL-internals-leak class of bug as `WHEN`/`UNLESS`/`LOOP`
before them. Two directions were proposed: (a) keep extending the
portable-override allowlist one macro at a time as BDD specs surface
each failure, or (b) adopt a portable standard-macro layer wholesale.

**Decision, made explicitly at the start of this work (not implicitly
by whichever fix happened to compile first)**: a hybrid of the two.
Maintain a small, closed, explicitly-documented set of portable
expanders for exactly the standard macros structurally necessary
(`DEFUN`, `DEFMACRO`, `WHEN`, `UNLESS`, `COND`, `INCF`, `DECF`,
`DESTRUCTURING-BIND`, plus `LOOP` via Khazern), each producing only
genuine ANSI special operators or other already-vetted entries in this
same set — never delegating any of these specific symbols to the live
SBCL image at all. Everything else (ordinary function calls,
genuinely user-defined macros, and any standard macro not on this
list) still goes through the live-image bridge as before. This is
scoped to exactly what the 13 BDD specs need, not a full portable
reimplementation of the standard library, and not open-ended
whack-a-mole either — the allowlist is the actual deliverable, and any
future addition follows the same discipline (confirm by direct
testing, then add the smallest portable expander that fixes it).

**Root causes confirmed by direct backtrace debugging:**

- `CL:COND`: SBCL's "prognify" fast-path optimization, for a clause
  with no body forms (e.g. a trailing `(t)` clause — exactly what
  Khazern's `WHEN`-clause compilation produces), calls
  `SB-C::%COERCE-TO-POLICY` directly on the foreign environment object.
  Same root cause class as the `WHEN`/`UNLESS` issue from #3.
- `CL:DESTRUCTURING-BIND` and `CL:INCF`/`CL:DECF`: both internally
  check whether their target/place might be a symbol-macro by calling
  SBCL-internal `%MACROEXPAND-1` directly on the macroexpansion-time
  environment, via `SB-IMPL::MACROEXPAND-FOR-SETF`/`GET-SETF-EXPANSION`
  machinery. Confirmed via direct backtrace on both forms.

**Fixes applied** (all in `src/environment.lisp`):

- `%portable-cond-expander`: expands to nested `IF`s. A test-only
  clause (no body) needs a fresh temporary to avoid re-evaluating the
  test, per CLHS 5.3.
- `%dbind-bindings` / `%portable-destructuring-bind-expander`: a
  from-scratch portable destructuring implementation using only
  `LET*`/`CAR`/`CDR`, replacing `CL:DESTRUCTURING-BIND` entirely
  (including inside sext's own `%portable-defmacro-expander`'s
  generated code, removing a chicken/egg dependency on the override
  table). Supports required parameters (including nested
  sub-lambda-lists), `&OPTIONAL` (default + supplied-p), `&REST`/
  `&BODY`, and `&KEY` (default + supplied-p). Does NOT support
  `&WHOLE`, `&ENVIRONMENT`, `&ALLOW-OTHER-KEYS` validation, or nested
  patterns inside `&OPTIONAL`/`&KEY` — none of the current 13 BDD specs
  need them; documented as an explicit limitation rather than silently
  dropped, same discipline as everywhere else in this file. Verified
  correct for both flat (`(test &body body)`, DUMP-9's actual fixture)
  and nested (`((a b) form &body body)`) lambda lists by direct testing
  through the real CST-to-AST pipeline.
- `%portable-incf/decf-expander`: scoped explicitly to simple-symbol
  places only (the only shape Khazern's accumulator update needs, and
  the only shape any current BDD spec needs) — expands directly to
  `(setq place (+ place delta))` / `(setq place (- place delta))`,
  bypassing `GET-SETF-EXPANSION` entirely for this case. Compound
  places (e.g. `(incf (aref a i))`) signal a clear, explicit error
  rather than being silently mishandled — documented limitation, not a
  silent gap.

**A second, independent bug found and fixed in the same pass — the
ctype glue:** issue #3's hand-written ~70-line `cleavir-ctype` ↔
external-`ctype`/`ctype/tfun`-library glue layer (modeled on Cleavir's
own `Example/type.lisp`) was not just unnecessary but actively buggy.
`cleavir-ctype` ships its OWN complete default implementation
(`Ctype/default.lisp`, unconditionally part of the `:cleavir-ctype`
ASDF system per its own `.asd` — confirmed by reading it directly —
representing ctypes as plain CL type specifiers and using `CL:SUBTYPEP`
directly, zero client code required). The custom methods specialized
on `SEXT-SYSTEM` returned CLOS objects from the external `ctype`
library for `TOP`/`FUNCTION`/`VALUES`/etc., while every OTHER
`cleavir-ctype` generic function sext hadn't overridden (`CLASS`,
`CONJOIN/2`, `NEGATE`, `TOP-P`, ...) silently fell back to
`default.lisp`'s unspecialized (T-applicable) methods, which assume
the plain-type-specifier representation throughout. Mixing the two
crashed with `"bad thing to be a type specifier: #<CTYPE:CONJUNCTION
T>"` as soon as a `DECLARE TYPE` form was processed (LOOP's
accumulator type declaration, via Khazern, triggered it). Fix: deleted
the entire custom glue block; replaced with a single small helper,
`%unconstrained-function-type`, built entirely from `cleavir-ctype`'s
own constructors (`cleavir-ctype:function`/`top`/`values`), relying on
`default.lisp` for everything else. Removed `ctype`/`ctype/tfun` from
`sext.asd` and `qlfile` entirely — sext never needed that dependency.

**Verification**: all 13 BDD-relevant fixture shapes pass through the
real `sext` ASDF system, including: simple `defun`, `defun`+docstring,
four LOOP variants (`for/when/sum` — DUMP-8's actual fixture — plus
`for/when/collect`, `for/collect`, and simple counting),
`defmacro` (DUMP-9's actual fixture, plus a nested-destructuring
variant), `defpackage`, and multiple top-level forms. Additionally,
the resulting LOOP AST was walked (via `cleavir-ast:children`) and
confirmed to genuinely contain `GO-AST`/`TAG-AST`/`IF-AST`
control-flow nodes — not opaque syntax — validating the core
Cleavir-vs-naive-walker differentiator this project is built on. A
clean full-system load produces zero warnings or notes in any of
sext's own source files (the one remaining `STYLE-WARNING` in the
build log is entirely inside Cleavir's own upstream source,
`Abstract-syntax-tree/general-purpose-asts.lisp`, unrelated to sext).

`src/walker.lisp` (the actual AST-to-JSON-shaped-IR conversion),
`src/serialize.lisp`, and `src/main.lisp` remain untouched stubs —
making AST conversion itself succeed for all needed input shapes was
the prerequisite; writing the walker is the next piece of work.

## Issue #4, #5 (walker), and #6 resolution (2026-06-20)

The actual `src/walker.lisp` implementation, plus `src/serialize.lisp`
and `src/main.lisp` (`dump-string`/`dump-file`/`main`), all landed
together — they turned out to be tightly coupled (the walker's output
shape and the JSON-encoding decision aren't really separable design
questions, and the walker can't be meaningfully tested without
`dump-string` wrapping it), so this resolves issues #4, #6, and the
remainder of #5 (the walker proper, as opposed to the CST-to-AST
conversion layer #5's earlier commits fixed) in one pass.

**Issue #4's question** — does `trivial-json-codec` or `shasht` handle
Cleavir's actual AST classes "out of the box" — was answered by reading
Cleavir's own source rather than testing the two candidates against it
(a better question turned out to be available): every AST class in
`Abstract-syntax-tree/general-purpose-asts.lisp` calls
`CLEAVIR-IO:DEFINE-SAVE-INFO` with its own meaningful, named slots
(confirmed directly — e.g. `function-ast`'s save-info includes `:name`,
`:docstring`, `:lambda-list`, `:body-ast`; `call-ast`'s includes
`:callee-ast`, `:argument-asts`, `:inline`). This is Cleavir's *own*
canonical "what's interesting about this node" protocol, used
internally for Cleavir's own model serialization/printing — a far
better foundation than blind MOP slot introspection (which would
surface internal bookkeeping never meant for serialization) and than
hoping a generic CLOS-JSON codec's defaults happen to produce something
sensible for an object graph with deliberate sharing. Given that,
**neither `trivial-json-codec` nor `shasht` is needed at all**:
`src/walker.lisp` does its own recursive descent via `cleavir-io:save-info`,
fully flattening every AST node down to plain hash-tables/vectors/
strings/numbers/symbols/booleans before handoff to `src/serialize.lisp`,
which only needs a thin pass-through to `com.inuoe.jzon:stringify` (a
JSON writer for already-plain data — already a dependency, since it's
what the test suite itself parses output with). Both unneeded
dependencies removed from `sext.asd`/`qlfile`.

**Object identity/sharing**: Cleavir's AST is generally tree-shaped, but
some nodes — most commonly `lexical-variable`/`lexical-ast` — are
deliberately referenced from multiple places (a variable bound once,
read or `setq`'d several times). The walker assigns each AST node a
sequential `:id` the first time it's encountered and emits `{"ref":
id}` on subsequent encounters instead of re-expanding — bounded output,
no risk from a true cycle if one ever exists, and useful in its own
right for downstream Rego/SARIF correlation.

**Symbol case**: standard-case (unescaped, read as upper-case) symbol
names are downcased in JSON output, matching how `*print-case*
:downcase` conventionally renders them and matching what the BDD specs
actually assert (e.g. `(search "add" json-str)`, lowercase, against a
function literally named `add`). Genuinely mixed-case symbols (created
via `|...|` escapes) are left exactly as interned.

**A determinism issue found and fixed in the same pass**: every AST
node's `:origin` slot holds a Concrete-Syntax-Tree CST object, whose
default `print-object` embeds an opaque, non-deterministic memory
address (`#<CONS-CST raw: ... {1002DC5813}>`). Walking that naively
would have made `dump-string`'s output non-reproducible run-to-run for
identical input — a real defect for a tool meant to feed reproducible
supply-chain/SBOM tooling, not just a cosmetic one. Fixed by
special-casing CST objects in the walker to extract
`concrete-syntax-tree:raw` (the library's own accessor for "the
underlying s-expression") and walk that instead — verified
byte-for-byte identical output across repeated runs on the same input.
(`concrete-syntax-tree:source` would give genuine source-location info
or line/column, but is `nil` throughout sext's current pipeline since
`dump-string`/`dump-file` don't bind Eclector's source-tracking client;
a future issue could wire that up if line/column info in `origin`
becomes valuable to a consuming policy.)

**`NIL` encoding, a deliberate, documented tradeoff**: a bare Lisp
`NIL` slot value (as opposed to an empty list reached through normal
list recursion, which is unambiguous) is encoded as JSON `false`,
matching `com.inuoe.jzon`'s own native convention exactly. This means a
slot that's conceptually "absent" and a slot that's the boolean value
`NIL` are indistinguishable in the output, which is an inherent
ambiguity of Lisp's own `NIL` (not something this walker introduces or
could fully resolve generically without per-slot semantic knowledge
this walker doesn't have). Not currently a problem for any of the 13
BDD specs; flagged here rather than left silently undocumented.

**Reading/conversion order**: `dump-string` reads and converts each
top-level form one at a time (not "read everything, then convert
everything"), so a compile-time side effect from an earlier form —
most commonly `in-package` — is visible when reading later ones,
matching ordinary `cl:load` semantics. `*compiler*` is bound to
`cl:eval` per the reasons already documented in `environment.lisp`'s
"EVAL / CST-EVAL" section.

**Verification**: all 13 BDD specs pass (16/16 checks), on the first
full run against the real implementation — no iteration needed beyond
the determinism fix above, which was caught by manual inspection of
actual output rather than by a failing spec (no current spec probes
reproducibility). A clean full-system load produces zero warnings in
any of sext's own source files; the only warnings anywhere in the
build log are pre-existing, upstream (Cleavir's own source) or in
`test/fiveam/test-sext.lisp` itself (an unused-variable style-warning
in one test, an undefined free variable check in the suite's own
runner) — neither touched, since both predate this work and aren't
caused by it.

Remaining open work: issue #7 (Roswell binary build), issue #8
(40ants-ci linter wiring), issues #1/#2 (docs). None started.

## Code review correction (2026-06-20): defun-returning-lambda anti-pattern

Flagged in review: `%portable-incf/decf-expander` in
`src/environment.lisp` was a `defun` whose entire body was a single
`(lambda (form env) ...)`, used as a closure factory at two call sites
(`'incf`/`'decf`) with a runtime `ecase` inside the closure dispatching
on a value that's actually fixed per call site. Since
`CLEAVIR-ENVIRONMENT:FUNCTION-INFO` is looked up on every `INCF`/`DECF`
form converted (not once at load time), this meant a fresh closure
allocation plus a re-checked branch on every single use — overhead for
a branch whose outcome never varies for a given call site, and the
only expander in the file that wasn't a plain named function
referenced via `#'` (worse for debuggability too: anonymous
closures-from-factories don't show up by name in backtraces).

**Fix**: replaced with `%define-portable-incf/decf-expander`, a
`defmacro` generating two separately-named, statically-specialized
functions (`%portable-incf-expander`, `%portable-decf-expander`) with
the arithmetic operator baked in as a literal at definition time via
the standard nested-backquote `,',x` idiom — verified directly
(`macroexpand-1` + functional test of both generated functions plus
the error path) before trusting it, not just inspected. Call sites
updated to `#'%portable-incf-expander`/`#'%portable-decf-expander`,
consistent with every other entry in the dispatch table. All 16 BDD
checks still pass; `environment.lisp` still compiles with zero
warnings.

General principle this corrects toward: when a function's "shape" is
parameterized by something known at the point the code is *written*
(here: there are only ever two instantiations, INCF and DECF, and
which one applies is fixed per call site), prefer a macro generating
named definitions over a runtime closure-returning factory with an
internal runtime branch on that fixed parameter.

## Issue #7 notes (2026-06-20): Roswell binary verification

Verified by direct testing throughout -- Roswell 26.02.116 (bundled
SBCL 2.6.5, a different version from this project's dev-sandbox SBCL
2.2.9) and qlot 1.x installed via the official CI install script.
Two real bugs found and fixed, both only catchable by actually running
the tools, not by inspecting dist metadata by hand:

**qlfile project-vs-system-name bug.** `ql <name>` in qlfile syntax
takes a Quicklisp PROJECT name (per the dist's releases.txt), not
necessarily an ASDF SYSTEM name -- the two only coincide when a
release's primary system shares the release's name. A live
`qlot install` against this repo's qlfile failed repeatedly on
`com.inuoe.jzon` and `khazern-extrinsic`, even though both names
appear as valid system-names in the dist's systems.txt (which lists
every system a release provides, without making the project/system
distinction obvious -- checking systems.txt by hand wasn't enough to
catch this). Confirmed via releases.txt: the "jzon" project ships
`src/com.inuoe.jzon.asd`; the "eclector" project ships both
`eclector.asd` and `eclector-concrete-syntax-tree.asd` in the same
tarball; the "khazern" project ships both `khazern.asd` and
`khazern-extrinsic.asd` in the same tarball. Fixed: `ql com.inuoe.jzon`
-> `ql jzon`; the `ql eclector-concrete-syntax-tree` and
`ql khazern-extrinsic` lines removed entirely as redundant -- once the
parent project is `ql`'d, ASDF finds the sub-system on disk
automatically, no separate qlfile line needed. sext.asd's own
:depends-on list was correct all along and untouched (it's the ASDF
SYSTEM-name namespace, a different thing from qlfile's project-name
lookups). Verified: a clean `qlot install` against the fixed qlfile
succeeds 8/8.

**Standalone binary's SB-CLTL2 require failure, and the fix.**
`ros build roswell/sext.ros` succeeded (exit 0, produced a real ELF
binary) on the *first* attempt, with the original script structure
(SEXT loaded inside MAIN, deferred until the binary is actually
invoked with a file argument). But running that binary against a test
file failed: `ASDF could not load sb-cltl2 because Don't know how to
REQUIRE sb-cltl2` -- an unhandled SB-INT:EXTENSION-FAILURE, traced via
full backtrace to src/environment.lisp's `(require :sb-cltl2)`.
Root cause: `ros build` only compiles/saves the .ros script's own
top-level forms (DEFPACKAGE, DEFUN MAIN) into the image -- it does NOT
invoke MAIN during the build, so when SEXT's own load was deferred
into MAIN, the SB-CLTL2 contrib module was never actually loaded into
the saved image at all. It only got REQUIRE'd for the first time at
actual runtime, inside the standalone saved/restored binary process --
where the contrib-module-finding machinery doesn't behave the same way
it does for a normal `ros`/`sbcl` invocation (confirmed by elimination:
the exact same SEXT load, via `qlot exec ros -e '(asdf:load-system
"sext")'` in an ordinary process, succeeds cleanly on the same Roswell
SBCL 2.6.5 -- the difference is specifically the saved-and-restored
standalone image, not the SBCL version or the code itself).

Fixed: moved `(asdf:load-system :sext)` (and the central-registry
push it depends on) out of MAIN and up to the script's own top level,
so it runs eagerly whenever the script is loaded/compiled --
including during `ros build`, which bakes SEXT and SB-CLTL2 into the
saved image instead of deferring the load to first invocation. MAIN
is now just `(funcall (find-symbol "MAIN" (find-package :sext))
argv)`, nothing else. This also means `ros build` now surfaces any
SEXT load-time error at build time (better CI signal) instead of
deferring all error detection to first invocation, and MAIN no longer
redoes ASDF's full dependency-graph walk on every single run.
Re-verified after the fix: `ros build roswell/sext.ros` succeeds, and
the resulting binary correctly reads a file path argument, writes
valid (JSON-parser-checked) JSON to stdout, runs deterministically
across repeated invocations, and exits 0.

**`--help`/`-h` implemented** (src/main.lisp), removing the need for
the `--help || true` escape hatch that was in the CI build job: prints
usage to stdout and exits 0, checked anywhere in ARGS (not just first
position, the common CLI convention) so it works even combined with
other flags. No-args now also exits 1 with usage on *ERROR-OUTPUT*,
rather than signalling an unhandled Lisp condition from PATHNAME on
NIL. Both new behaviors covered by BDD specs (DUMP-14, DUMP-15);
verified directly against the actual standalone binary, not just at
the Lisp function level. All 21 BDD checks pass (FiveAM counts
individual `is` assertions, not test names -- the two new tests add
five assertions between them, bringing the prior 16 to 21).

Remaining for issue #7: sub-item 3 (`ros install denzuko/sext` UX)
needs a tagged release, which doesn't exist yet -- not started, and
reasonably out of scope until a release is cut. Sub-items 1, 2, and 4
are done and verified.

## Issue #8 notes (2026-06-20): 40ants-ci linter/critic verification

**Distribution mechanism, confirmed.** `40ants-ci/jobs/linter` and
`jobs/critic` are NOT GitHub Actions to reference via `uses:` -- they're
a Lisp-side workflow GENERATOR (a `defworkflow` DSL: e.g.
`(defworkflow ci :jobs ((40ants-ci/jobs/linter:linter)
(40ants-ci/jobs/critic:critic)))`) that PRODUCES `.github/workflows/*.yml`
content; you run that Lisp code locally/once to generate the YAML, you
don't reference 40ants-ci from inside a workflow at CI time. The YAML it
generates uses `40ants/setup-lisp@v4` (checkout + Roswell/qlot setup,
already in this workflow) followed by a plain `run: qlot exec sblint
<asd-file>` step for the linter job, and an analogous Lisp Critic
invocation for the critic job.

**Why this job does NOT actually use `qlot exec`, despite that being
the documented pattern.** Tried directly: `qlot exec sblint sext.asd`
fails, because `qlot exec` swaps the whole Quicklisp CLIENT environment
for that process to the project-local `.qlot/` one -- but sblint's own
Roswell script needs to `(ql:quickload '(:sblint ...))` itself on
startup (it's a thin wrapper, not pre-baked), and `:sblint` isn't a
dependency of THIS project, so it's invisible inside the qlot-swapped
environment. Tried calling sblint's internal API directly
(`sblint/run-lint:run-lint-asd`) inside a `qlot exec ros -e` session
instead, pushing sblint's `~/.roswell/local-projects/` path onto
`asdf:*central-registry*` to route around the self-quickload problem:
got further (sblint itself loads) but then hit `Component "swank" not
found` -- sblint depends on swank, which (like sblint itself) isn't a
dependency of this project and so isn't in qlot's local environment
either. The fundamental tension: sblint/lisp-critic need access to
BOTH their own tooling dependencies (global Quicklisp/Roswell
environment) AND the target project's dependencies (Cleavir, only
reachable via this project's qlot setup) -- two overlapping dependency
graphs that don't compose cleanly when qlot's `exec` deliberately
isolates one from the other.

**The fix that works**: run sblint/lisp-critic normally, in the global
Roswell/Quicklisp environment (where their own tooling dependencies
resolve fine, exactly as confirmed by direct testing), and supply
Cleavir's location via the `CL_SOURCE_REGISTRY` environment variable
with `:inherit-configuration` -- this ADDS to the normal search path
rather than replacing it, so sblint/lisp-critic keep finding their own
deps from the global environment while ALSO finding Cleavir. Cleavir is
fetched via a direct `git clone` to a fixed path for this job
specifically (not qlot's hash-keyed cache path, which is fine for an
interactive session but too fragile to hardcode into CI) -- a small
amount of duplication (Cleavir gets fetched twice across the `lint` and
`unit-tests`/`build` jobs) traded for robustness and avoiding a fight
with qlot's isolation. Verified directly against the real sext system.

**Lisp Critic: verified working end-to-end**, and a live run surfaced
real evidence for the blocking-vs-advisory decision (issue #8 sub-item
3): it flagged `CLEAVIR-ENVIRONMENT:EVAL`'s `(EVAL FORM)` call as
`[evil-eval]` -- but that's a deliberate, already-documented design
choice (src/main.lisp's `%CST-TO-AST` docstring, environment.lisp's
"EVAL / CST-EVAL" section), not a real problem. Decided: **advisory**
(`continue-on-error: true`), specifically because of this concrete
false-positive, not just a generic "style tools should be advisory"
policy -- idiom/style advice a human reviews, not a hard gate that
would force working around legitimate, justified exceptions.

**sblint: still genuinely broken, this time properly root-caused via a
real CI run, not local re-testing.** Even with the CL_SOURCE_REGISTRY
fix (which did resolve the original "cleavir-cst-to-ast not found"
failure), a live run hits `Component "trinsic" not found`, traced via
backtrace into sblint's own dependency walk of `khazern-extrinsic`.
Checked the obvious explanation directly: `khazern-extrinsic.asd`'s own
`:depends-on` is just `("khazern")` -- nothing resembling "trinsic"
anywhere in it. Wired into CI as non-blocking pending root-cause, not
as a permanent policy decision.

**A same-day local re-test wrongly concluded this was resolved** --
re-ran the exact CI command against a freshly reinstalled `sblint` and
a fresh Cleavir clone, with `~/.cache/common-lisp` cleared, and it
passed cleanly twice. That re-test was itself unreliable: the local
sandbox still had cached Quicklisp dist *metadata* (not just FASLs)
from much earlier, unrelated work in the same session, which a fresh
GitHub Actions runner doesn't have -- clearing `~/.cache/common-lisp`
ruled out stale compiled output but not stale dist-resolution state.
Committed and merged sblint back as a blocking gate on the strength of
that flawed local result, without ever checking a real CI run.

**Corrected (2026-06-21, later the same day), after actually checking
real GitHub Actions run logs via the API** for the first time this
session (prompted by trying to verify issue #11's two actions end to
end, which surfaced that CI itself had several genuine, undetected
failures -- see the LISP-env-var and qlot-exec-build fixes elsewhere in
this file). A real run reproduced the "trinsic" failure again, with a
full backtrace this time:
`SBLINT/UTILITIES/ASDF:ALL-REQUIRED-SYSTEMS` walks `"sext"` ->
`"khazern-extrinsic"` -> `"khazern"`, then asks ASDF to
`FIND-SYSTEM`/`DIRECT-DEPENDENCIES` on `"khazern"`, which somehow
resolves to looking for a system literally named `"trinsic"`. Likely
explanation, given `"trinsic"` is exactly `"extrinsic"` with `"ex"`
stripped off the front: a package-inferred-system name-splitting bug
in sblint's own dependency walker, specifically triggered by a system
name containing "extrinsic" as a substring -- not a problem in this
repo, khazern-extrinsic, or the CL_SOURCE_REGISTRY setup, and not
something fixable from this side without either an upstream sblint fix
or a different dependency-walking strategy. Reverted back to
non-blocking (`continue-on-error: true` restored) -- for real this
time, verified against an actual GitHub Actions run, not local
re-testing.

**The lesson, stated plainly**: this whole session's verification had
relied entirely on local sandbox testing, which never once exercised
the actual `40ants/setup-lisp@v4`-based dependency installation CI
uses, and accumulated cached Quicklisp/dist state across many hours of
unrelated work that a fresh runner never has. Local verification is
necessary but not sufficient for anything CI-shaped; checking real
workflow run results via the GitHub Actions API is the only thing that
actually confirms CI works, and should have been done much earlier and
more routinely throughout this session, not just once issue #11's own
verification need surfaced the gap.


## Issue #1 notes (2026-06-20): JSON schema documentation

`docs/schema.md` written, derived directly from `src/walker.lisp` and
Cleavir's own `CLEAVIR-IO:DEFINE-SAVE-INFO` declarations
(`Abstract-syntax-tree/general-purpose-asts.lisp`) -- every per-type
field table entry was checked directly against that source before
being written, not transcribed from memory (caught and fixed one near-
miss this way: double-checked `if-ast`'s exact fields, which turned
out correct, but the discipline is the point). README updated to
reference it and to drop the stale "pre-implementation" status
language, which had drifted badly out of date relative to the actual
state of the repo by this point in the session.

**Real, previously-undiscovered limitation found and filed (issue
#14)** while building a fixture for the example policy: `sext`
currently can only successfully dump source where every called
function is a standard/built-in CL function or already loaded into the
running image -- not a function merely defined elsewhere in the same
*file*, even earlier in the exact same `dump-string`/`dump-file` call.
Verified directly: `(defun bar (x) x) (defun foo (x) (bar x))` fails
identically to a call to a wholly-undefined function. Root cause:
`%dump-forms-to-asts` converts each top-level form to an AST data
structure, it never executes any of them, so an earlier `DEFUN`'s
runtime `(setf (fdefinition ...))` effect never fires and Cleavir's
compile-time environment never learns the function exists. This is
deliberate, correct Cleavir behavior (real compilers need exactly this
for inlining/type-checking), not a sext bug per se, but it's a real
practical constraint on `sext`'s usefulness against ordinary multi-
function source files, not just multi-file systems as originally
suspected -- the issue was filed, then corrected via a follow-up
comment once the more precise (same-file, not just cross-file) version
of the finding was confirmed. Also flagged in the same issue:
`dump-string`'s `handler-case` discards the real underlying condition
entirely (`(declare (ignore e))`) before re-signalling a generic
`SEXT-PARSE-ERROR`, making this kind of failure hard to diagnose from
the CLI's error message alone.

**Example policy fixed and, unlike before, actually verified.** The
original `policy/examples/no_pre_wrapped_filter_args.rego` was
explicit pseudocode against a speculative schema using field names
(`operator`, `clauses`, `location`) that don't exist anywhere in the
real schema (Cleavir's `COND` macroexpands to nested `IF-AST`s --
there's no `cond-ast`/`clause`/`test` structure to match on at all).
Rewritten against the real schema and shape (`call-ast`/`callee-ast`/
`argument-asts`/`if-ast`/`test-ast`), and actually proven correct via
`opa test` against two real, `sext`-produced fixtures (not just `opa
eval`'d once by hand) -- `test/policy/fixtures/` plus a proper
`*_test.rego` file, both passing. Caught and fixed two real Rego
mistakes in the process, both via actually running `opa eval`/`opa
test` rather than trusting the policy text on inspection: a Lisp-style
`~`-continuation inside a string literal (not valid Rego syntax), and
`form.callee-ast.type`-style dot-notation on a hyphenated key, which
Rego parses as a subtraction expression (`callee - ast`) rather than
field access -- needs bracket notation (`form["callee-ast"].type`) for
any hyphenated key, throughout. The fixture itself uses
`uiop:ensure-list` rather than the original bug's `invoke-filter-chain`
name, specifically because of the issue #14 limitation just found
(`invoke-filter-chain` isn't a real, already-loaded function); the
policy's `canonical_disambiguators` set keeps both names so it's ready
once #14 is resolved. Full rationale in `test/policy/README.md`.

Issue #2 (40ants-doc `docs/index.lisp`) not yet started.

## Issue #2 notes (2026-06-21): 40ants-doc integration

`docs/index.lisp` written: `@sext-manual` (top-level section, README-
style pitch plus links to `docs/schema.md` and `policy/examples/`) and
`@sext-api` (locatives for the actual exported API -- `dump-string`,
`dump-file`, `main`, and the three condition types -- checked against
`src/package.lisp`'s real `:export` list, not assumed). Verified by
actually loading the `sext/doc` ASDF system (which was previously
declared but broken -- the component it names didn't exist) rather
than just writing plausible-looking `DEFSECTION` syntax and trusting
it: confirms both sections bind correctly. Note for whoever next
builds HTML/Markdown output from this: `40ants-doc` alone (what
`sext/doc` depends on) only provides `DEFSECTION` and the
cross-reference machinery; actually rendering to files needs the
separate, heavier `40ants-doc-full` system (markdown parser and other
deps `40ants-doc` deliberately doesn't pull in by default) -- noted
directly in `docs/index.lisp`'s own header rather than left implicit.

## Issue #11 notes (2026-06-21): GitHub Actions

Two actions, matching the issue's own description ("first installs
the sext binary the second consumes it"):

**`denzuko/setup-sext`** -- a new, separate repo (standard
`actions/setup-X` convention; created with the same PAT used
throughout this session, confirmed via a throwaway probe repo it has
repo-creation rights before committing to the real one). Composite
action: installs Roswell + qlot if missing, resolves the `version`
input (branch/tag/SHA) to a commit SHA via `git ls-remote` for a
stable `actions/cache@v4` key (so it doesn't go stale against a moving
branch, and doesn't rebuild every run against an unchanged target),
clones+builds via `qlot install` + `qlot exec ros build
roswell/sext.ros` (with a tested fallback from a shallow `--branch`
clone to a full clone + checkout, for when `version` is a raw commit
SHA rather than a named ref -- `--branch` only accepts refs), installs
to `~/.local/bin`, verifies via `sext --help`. The full Roswell ->
qlot -> build -> install pipeline, the version-resolution `git
ls-remote` call, and the branch/tag/SHA clone fallback were all
actually run end-to-end in this sandbox (built a real ~17MB working
binary, ran `sext --help` successfully) before being committed -- only
the composite-action YAML orchestration itself (`actions/cache@v4`
semantics, `$GITHUB_PATH`/`$GITHUB_OUTPUT`, input interpolation)
couldn't be verified, since no real GitHub Actions runner is available
here. Noted honestly in the repo's own commit message and README: a
real workflow run is still needed to confirm that part end-to-end.

**`denzuko/sext`'s own action** -- `action.yml` at this repo's root
(no new repo needed; referenced as `uses: denzuko/sext@develop`).
Accepts `source` (a file *or* a directory) and `output`, since the
issue's own pipeline example shows `source: ./src` (a directory) but
the `sext` binary only ever dumps one file. Combines multiple files'
output as `[{"file": ..., "ast": [...]}, ...]` -- grouped by file,
*not* a flat merge of the per-file arrays, because each file's AST
node `id` numbering restarts at 1 independently (documented in
`docs/schema.md`'s "IDs are stable within a single dump" line) and
flattening would silently produce colliding, misleading IDs. For a
file that fails to dump (issue #14's limitation in practice -- most
real multi-file directories will hit this on at least one file),
records `{"file": ..., "error": ...}` and continues with the rest by
default, rather than aborting the whole action; a `fail-on-error`
input opts into strict fail-fast instead. The exact bash combining
logic (including the hand-assembled JSON -- one entry per file, comma
placement, the success/failure branches) was extracted to a standalone
script and actually run against a real three-file test directory (two
dumpable, one deliberately hitting issue #14) before being placed in
`action.yml`; the resulting output was validated as well-formed JSON
with `python3 -m json.tool`, not just assumed correct from reading the
bash. `docs/schema.md` and the README both updated to document this
action's distinct (file-grouped) output shape, separately from the
binary's own per-file schema.

## Repo hygiene (2026-06-21): LICENSE file

README.md and `sext.asd` both claimed BSD-2-Clause throughout this
whole session, but no `LICENSE` file actually existed in the repo --
a real gap (no license file means GitHub's own license detection has
nothing to find, and downstream consumers have no actual license text
to point to). Added standard BSD-2-Clause text. Noted, not acted on:
`qlfile.lock` is `.gitignore`'d (`*.lock` pattern) -- this looks like
a deliberate existing project convention from before this session, not
something introduced here, so left alone rather than second-guessed;
worth flagging that it sits in some tension with docs/schema.md's
"qlfile pins Cleavir to a specific git commit for reproducibility"
framing, since the regular Quicklisp-dist-sourced deps (jzon, etc.)
aren't pinned the same way without a committed lock file.

## Issue #14 follow-up (2026-06-21): a third design option

Posted a design analysis on the issue rather than picking a direction
unilaterally. Grounded in actually reading `src/environment.lisp`'s
`FUNCTION-INFO` method (not speculation): it delegates straight to
`SB-CLTL2:FUNCTION-INFORMATION`, returning `NIL` -- fatal to Cleavir's
CST-to-AST converter -- whenever SBCL itself has no knowledge of a
name. Proposed a third option alongside the issue's original two (load
the whole system first, vs. accept single-form scope): a cheap
pre-declaration pass that just *reads* (never executes) every
`DEFUN`/`DEFGENERIC` name across the unit being dumped and extends
`FUNCTION-INFO` (already a generic function, already has an `:AROUND`
precedent for `INCF`/`DECF`) to synthesize a `GLOBAL-FUNCTION-INFO` for
any pre-collected name, without requiring it to be genuinely fbound.
Resolves the same-file (and, extended across files, cross-file) case
without ever running arbitrary source as a side effect of dumping its
AST -- which matters more for a tool whose deployment context is
security/policy-gate tooling than it would for an ordinary dev tool.
Flagged as the most promising of the three on safety/cost grounds, not
implemented -- still needs a direction decision before any of the
three gets built.

## Issue #14 follow-up (2026-06-21): fixed the smaller sub-item

The bigger architectural question (load-system-first vs. single-form
scope vs. the pre-declaration option proposed above) is still
undecided -- not touched here. But the issue's smaller, immediate bug
*is* fixed: `dump-string`'s `handler-case` previously discarded the
real underlying condition entirely (`(declare (ignore e))`) before
re-signalling a generic `SEXT-PARSE-ERROR` whose report was just
"failed to parse source: <whole source echoed back>" -- no way to
tell a genuine reader error from a `NO-FUNCTION-INFO` error from
anything else without re-deriving it.

Fixed: `SEXT-PARSE-ERROR` gained a `CAUSE` slot (the real condition,
stored but not exported -- matches the existing convention that
`SEXT-PARSE-ERROR-SOURCE` isn't exported either; callers interact via
the condition's printed report, exactly how `MAIN`'s own CLI error
path already works, not via accessors), and its `:REPORT` now leads
with the cause's own message before the (now clearly separated, on
its own line) source text. `dump-string` passes `:cause e` through
instead of discarding it.

Verified directly, not just inspected: both a genuine reader error
(unbalanced parens) and a real `NO-FUNCTION-INFO` case now produce
visibly different, individually-specific report text -- the
`NO-FUNCTION-INFO` case's report names the actual undefined function
(`AN-UNDEFINED-FUNCTION`), not a generic message. New test added,
`DUMP-16-parse-error-report-includes-real-cause`, covering both cases
and asserting they differ and that the undefined function's name
actually appears. All 25 BDD checks (21 previous + 4 new from
DUMP-16's multiple `is` assertions) pass; `opa test` and a full clean
binary rebuild both still succeed.

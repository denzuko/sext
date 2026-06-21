# policy/examples/no_pre_wrapped_filter_args.rego
#
# EXAMPLE / REFERENCE POLICY ONLY. Not production policy for any
# specific organization -- demonstrates that the sext JSON schema
# (docs/schema.md) is usable for Rego policy authoring. Real
# organizational policy belongs in a separate, organization-owned repo
# that depends on sext as a tool, the same way podcast-mgr's actual
# policy depends on but does not contain clang/opa/cdxgen.
#
# This example encodes, in Rego, the exact bug class found during the
# mlisp session that motivated this project: a function that receives
# a configured filter-program value and wraps it in (list value) BEFORE
# passing it to the canonical filter-chain function, which silently
# defeats that function's own internal type-dispatch logic. The fix
# was: never pre-wrap; pass the raw configured value through and let
# the canonical function handle all three cases (nil/string/list) itself.
#
# Generalized as a policy: "no call site should pattern-match on the
# shape of a value about to be passed into a function whose entire
# purpose is to do that same pattern-match." This is checkable
# structurally: a CALL-AST to a known canonical-disambiguator function,
# where one of its ARGUMENT-ASTS is itself an IF-AST whose TEST-AST is
# a call to a type-dispatch predicate (LISTP/NULL).
#
# Verified against docs/schema.md and two real fixtures (not
# speculative pseudocode): `opa eval` run directly against actual
# `sext`-produced JSON for both a violating and a clean example. See
# test/policy/README.md for the exact fixtures and invocations.

package sext.examples.no_pre_wrapped_filter_args

import rego.v1

canonical_disambiguators := {"ensure-list", "invoke-filter-chain"}

type_dispatch_predicates := {"listp", "null"}

deny contains msg if {
	some form in walk_ast_nodes
	form.type == "call-ast"
	form["callee-ast"].type == "constant-fdefinition-ast"
	form["callee-ast"].name in canonical_disambiguators
	some arg in form["argument-asts"]
	arg.type == "if-ast"
	arg["test-ast"].type == "call-ast"
	arg["test-ast"]["callee-ast"].type == "constant-fdefinition-ast"
	arg["test-ast"]["callee-ast"].name in type_dispatch_predicates
	msg := sprintf(
		"call to %s receives a pre-disambiguated argument (id %d) -- disambiguation logic should live inside %s itself, not at the call site (see mlisp PR #137 for the exact bug this catches)",
		[form["callee-ast"].name, arg.id, form["callee-ast"].name],
	)
}

# Walks every AST-node object reachable anywhere in the input (the
# top-level array sext produces, or a single dumped form), at any
# nesting depth -- input shapes vary by which form a caller dumped, so
# this doesn't assume a fixed path. {"ref": id} back-reference objects
# are walked too, but never match `type == "call-ast"` (they only ever
# have a "ref" key), so they're harmless no-ops here rather than
# something that needs filtering out explicitly.
walk_ast_nodes contains node if {
	walk(input, [_, node])
	is_object(node)
}

package main

import "testing"

func TestCompile(t *testing.T) {
	tests := []struct {
		name    string
		query   string
		pattern string
		spec    string
	}{
		{"empty", "", "", ""},
		{"whitespace only", "   ", "", ""},
		{"fuzzy", "cfg", "^(?=.*c.*?f.*?g)", "F:cfg"},
		{"exact", "'foo", "^(?=.*foo)", "L:foo"},
		{"prefix", "^foo", "^(?=foo)", "L:foo"},
		{"suffix", "foo$", "^(?=.*foo$)", "L:foo"},
		{"prefix and suffix", "^foo$", "^(?=foo$)", "L:foo"},
		{"lone inverse yields nothing", "!foo", "", ""},
		{"and", "foo bar", "^(?=.*f.*?o.*?o)(?=.*b.*?a.*?r)", "F:foo\tF:bar"},
		{"positive with inverse", "foo !bar", "^(?=.*f.*?o.*?o)(?!.*bar)", "F:foo"},
		{"inverse prefix", "foo !^bar", "^(?=.*f.*?o.*?o)(?!bar)", "F:foo"},
		{"inverse suffix", "foo !bar$", "^(?=.*f.*?o.*?o)(?!.*bar$)", "F:foo"},
		{"or", "go$ | rb$", "^(?=.*go$|.*rb$)", "L:go\tL:rb"},
		{"and then or binds tighter", "foo bar | baz", "^(?=.*f.*?o.*?o)(?=.*b.*?a.*?r|.*b.*?a.*?z)", "F:foo\tF:bar\tF:baz"},
		{"negated or member", "foo | !bar", "^(?=.*f.*?o.*?o|(?!.*bar))", "F:foo"},
		{"escaped space fuzzy", `foo\ bar`, "^(?=.*f.*?o.*?o.*? .*?b.*?a.*?r)", "F:foo bar"},
		{"escaped space exact", `'foo\ bar`, "^(?=.*foo bar)", "L:foo bar"},
		{"meta escaped in exact", "'a.b", `^(?=.*a\.b)`, "L:a.b"},
		{"meta escaped in fuzzy", "a.b", `^(?=.*a.*?\..*?b)`, "F:a.b"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			pattern, spec := compile(tt.query)
			if pattern != tt.pattern {
				t.Errorf("compile(%q) pattern = %q, want %q", tt.query, pattern, tt.pattern)
			}
			if spec != tt.spec {
				t.Errorf("compile(%q) spec = %q, want %q", tt.query, spec, tt.spec)
			}
		})
	}
}

package main

import (
	"errors"
	"strings"
	"testing"
)

func TestRun(t *testing.T) {
	tests := []struct {
		name  string
		args  []string
		stdin string
		want  string
		err   error
	}{
		{"prefilter", []string{"prefilter", "'中文"}, "", "中文\n", nil},
		{"no prefilter without a positive term", []string{"prefilter", "!中"}, "", "", nil},
		{"rows", []string{"rows", "'中"}, "a\x001:中\n", header("a", "1") + match("a", "1", hl+"中"+rs), nil},
		{"mark", []string{"mark", "'中"}, "中\n", rev + "中" + unr + "\n", nil},
		{"a subcommand's name is a query too", []string{"mark", "rows"}, "rows\n", rev + "rows" + unr + "\n", nil},
		{"an older fm_rg.sh's lone query", []string{"'中"}, "", "", errUsage},
		{"no arguments", nil, "", "", errUsage},
		{"unknown subcommand", []string{"compile", "x"}, "", "", errUsage},
		{"extra argument", []string{"rows", "x", "y"}, "", "", errUsage},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			var b strings.Builder
			err := run(tt.args, strings.NewReader(tt.stdin), &b)
			if !errors.Is(err, tt.err) {
				t.Fatalf("run(%q) error = %v, want %v", tt.args, err, tt.err)
			}
			if b.String() != tt.want {
				t.Errorf("run(%q) = %q, want %q", tt.args, b.String(), tt.want)
			}
		})
	}
}

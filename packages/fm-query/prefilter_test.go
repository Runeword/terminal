package main

import (
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

// TestPrefilterIsNecessary runs each query's prefilter through rg, as fm_rg.sh
// does, and checks that every line the query accepts is among rg's: a line rg
// skipped could never be listed. It needs rg (a check input in default.nix).
func TestPrefilterIsNecessary(t *testing.T) {
	rg, err := exec.LookPath("rg")
	if err != nil {
		t.Skip("rg not on PATH")
	}
	corpus := []string{
		"config file",
		"cafe au lait",
		"café crème",
		"CAFÉ BAR",
		"İstanbul",
		"Kelvin K degrees",
		"straße straſſe",
		"\tindented\treturn value",
		"  return x  ",
		"foo_bar baz-qux foobar",
		`a.b.c (x) [y] {z} ^$ | \ * + ? # & ~ -`,
		"ＦＵＬＬＷＩＤＴＨ ｆｏｏ",
		"caf\xe9 au lait: foo",
		"c\xe9l x",
		"go.mod main.go x.rb y.py",
		"ΟΔΟΣ οδος",
		"line ending in crlf\r",
		"中文 汉字",
	}
	file := filepath.Join(t.TempDir(), "corpus")
	if err := os.WriteFile(file, []byte(strings.Join(corpus, "\n")+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	queries := []string{
		"cfg", "'onf", "'conf'", "'foo'", "^ret", "x$", "^return x$", "foo !bar", "!'bz baz", "go$ | rb$",
		"foo | !bar", "'foo", "'Foo", "FOO", "cafe", "café", "'cafe", "'istanbul", "'k", "'strasse", "ſ", "'ss",
		"'ｆｏｏ", "fullwidth", "'full", "cl", "'lait", `'\`, "'a.b", "'(x)", "'[y]", "'{z}", "'^$", "^a.b", "'#",
		"'~", "-", `foo\ bar`, `indented\ return`, "οδοσ", "'οδος", "'ΟΔΟΣ", "crlf$", "'b.c", "x y", "中", "'文 汉",
	}
	for _, query := range queries {
		re, ok := parse(query).prefilter()
		if !ok {
			continue
		}
		out, err := exec.Command(rg, "--no-config", "--ignore-case", "--no-filename", "--line-number",
			"--no-heading", "--color", "never", "-e", re, file).Output()
		if err != nil && (!isExit(err, 1) || len(out) != 0) {
			t.Fatalf("rg -e %q (query %q): %v", re, query, err)
		}
		found := map[int]bool{}
		for _, ln := range strings.Split(strings.TrimSuffix(string(out), "\n"), "\n") {
			if n, _, ok := strings.Cut(ln, ":"); ok {
				i, _ := strconv.Atoi(n)
				found[i] = true
			}
		}
		q := parse(query)
		for i, text := range corpus {
			var l line
			l.reset(strings.TrimSuffix(text, "\r"))
			if q.accepts(&l) && !found[i+1] {
				t.Errorf("query %q accepts line %d %q, which its prefilter %q skips", query, i+1, text, re)
			}
		}
	}
}

func isExit(err error, code int) bool {
	var ee *exec.ExitError
	return errors.As(err, &ee) && ee.ExitCode() == code
}

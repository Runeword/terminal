package main

import (
	"bytes"
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

func TestSplitTokens(t *testing.T) {
	tests := []struct {
		name string
		line string
		want []string
	}{
		{"empty", "", nil},
		{"spaces only", "   ", nil},
		{"single", "foo", []string{"foo"}},
		{"three", "a b c", []string{"a", "b", "c"}},
		{"tab delimited", "a\tb", []string{"a", "b"}},
		{"collapse runs", "a   b", []string{"a", "b"}},
		{"quoted space kept", `"a b" c`, []string{"a b", "c"}},
		{"quoted glob", `"my confs/*"`, []string{"my confs/*"}},
		{"unterminated quote runs to end", `"abc`, []string{"abc"}},
		{"quote mid-token", `a"b c"d`, []string{"ab cd"}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := splitTokens(tt.line); !reflect.DeepEqual(got, tt.want) {
				t.Errorf("splitTokens(%q) = %#v, want %#v", tt.line, got, tt.want)
			}
		})
	}
}

func TestDirectiveArgs(t *testing.T) {
	tests := []struct {
		name    string
		line    string
		keyword string
		want    string
		wantOK  bool
	}{
		{"simple", "Include foo", "include", "foo", true},
		{"case-insensitive", "iNcLuDe foo", "include", "foo", true},
		{"leading ws", "   include   a b", "include", "a b", true},
		{"equals separator", "Include=bar", "include", "bar", true},
		{"trailing preserved", "Include foo ", "include", "foo ", true},
		{"no separator is not a match", "IncludeFoo", "include", "", false},
		{"longer keyword is not a match", "Includes x", "include", "", false},
		{"other keyword", "Host x", "include", "", false},
		{"identityfile", "IdentityFile ~/.ssh/id", "identityfile", "~/.ssh/id", true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, ok := directiveArgs(tt.line, tt.keyword)
			if got != tt.want || ok != tt.wantOK {
				t.Errorf("directiveArgs(%q, %q) = (%q, %v), want (%q, %v)",
					tt.line, tt.keyword, got, ok, tt.want, tt.wantOK)
			}
		})
	}
}

func TestExpandIncludeToken(t *testing.T) {
	tests := []struct {
		tok, want string
	}{
		{"~/x/y", "/home/u/x/y"},
		{"/abs/path", "/abs/path"},
		{"rel.conf", "/home/u/.ssh/rel.conf"},
		{"../up.conf", "/home/u/.ssh/../up.conf"},
	}
	for _, tt := range tests {
		if got := expandIncludeToken(tt.tok, "/home/u", "/home/u/.ssh"); got != tt.want {
			t.Errorf("expandIncludeToken(%q) = %q, want %q", tt.tok, got, tt.want)
		}
	}
}

func TestExpandIdentityToken(t *testing.T) {
	tests := []struct {
		tok    string
		want   string
		wantOK bool
	}{
		{"~/.ssh/id", "/home/u/.ssh/id", true},
		{"/abs/key", "/abs/key", true},
		{"bare_name", "", false},
		{"%d/id_rsa", "", false},
	}
	for _, tt := range tests {
		got, ok := expandIdentityToken(tt.tok, "/home/u")
		if got != tt.want || ok != tt.wantOK {
			t.Errorf("expandIdentityToken(%q) = (%q, %v), want (%q, %v)", tt.tok, got, ok, tt.want, tt.wantOK)
		}
	}
}

// testEnv builds an isolated fake $HOME with an empty ~/.ssh and returns a
// sanitizer wired to capture stdout (masks) and stderr (warnings).
type testEnv struct {
	home, src, dst string
	s              *sanitizer
	out, errb      *bytes.Buffer
}

func newTestEnv(t *testing.T) *testEnv {
	t.Helper()
	base := t.TempDir()
	home, err := filepath.EvalSymlinks(base)
	if err != nil {
		t.Fatalf("resolve tempdir: %v", err)
	}
	src := filepath.Join(home, ".ssh")
	if err := os.MkdirAll(src, 0o700); err != nil {
		t.Fatalf("mkdir .ssh: %v", err)
	}
	sshReal, err := filepath.EvalSymlinks(src)
	if err != nil {
		t.Fatalf("resolve .ssh: %v", err)
	}
	out, errb := &bytes.Buffer{}, &bytes.Buffer{}
	return &testEnv{
		home: home, src: src, dst: filepath.Join(base, "dst"),
		out: out, errb: errb,
		s: &sanitizer{
			home: home, srcDir: src, dstDir: filepath.Join(base, "dst"),
			sshReal: sshReal, dotSSH: filepath.Join(home, ".ssh"),
			out: out, errW: errb, seen: make(map[string]bool),
		},
	}
}

func (e *testEnv) write(t *testing.T, rel, content string) {
	t.Helper()
	p := filepath.Join(e.home, rel)
	if err := os.MkdirAll(filepath.Dir(p), 0o700); err != nil {
		t.Fatalf("mkdir for %s: %v", rel, err)
	}
	if err := os.WriteFile(p, []byte(content), 0o600); err != nil {
		t.Fatalf("write %s: %v", rel, err)
	}
}

func (e *testEnv) run(t *testing.T) {
	t.Helper()
	if err := e.s.run(); err != nil {
		t.Fatalf("run: %v", err)
	}
}

func exists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}

func TestRunCopiesConfigIncludesAndKnownHosts(t *testing.T) {
	e := newTestEnv(t)
	e.write(t, ".ssh/config", "Include conf.d/*.conf\n")
	e.write(t, ".ssh/conf.d/a.conf", "# a\n")
	e.write(t, ".ssh/conf.d/b.conf", "# b\n")
	e.write(t, ".ssh/known_hosts", "kh\n")
	e.run(t)

	for _, rel := range []string{"config", "conf.d/a.conf", "conf.d/b.conf", "known_hosts"} {
		if !exists(filepath.Join(e.dst, rel)) {
			t.Errorf("expected %s in sanitized tree", rel)
		}
	}
	if e.out.Len() != 0 {
		t.Errorf("unexpected mask output: %q", e.out.String())
	}
	if e.errb.Len() != 0 {
		t.Errorf("unexpected warnings: %q", e.errb.String())
	}
}

func TestRunPubkeyBesideKey(t *testing.T) {
	e := newTestEnv(t)
	e.write(t, ".ssh/config", "IdentityFile ~/.ssh/id_ed25519\n")
	e.write(t, ".ssh/id_ed25519.pub", "ssh-ed25519 AAAAlocal me\n")
	e.run(t)

	got, err := os.ReadFile(filepath.Join(e.dst, "id_ed25519.pub"))
	if err != nil {
		t.Fatalf("read pubkey: %v", err)
	}
	if string(got) != "ssh-ed25519 AAAAlocal me\n" {
		t.Errorf("pubkey = %q, want the .pub beside the key", got)
	}
	if e.errb.Len() != 0 {
		t.Errorf("unexpected warnings: %q", e.errb.String())
	}
}

func TestRunAgentFallbackSingleKey(t *testing.T) {
	e := newTestEnv(t)
	e.s.agentLines = []string{"ssh-rsa AAAAG /home/x/.ssh/id_rsa"}
	e.write(t, ".ssh/config", "IdentityFile ~/.ssh/id_rsa\n")
	e.run(t)

	got, err := os.ReadFile(filepath.Join(e.dst, "id_rsa.pub"))
	if err != nil {
		t.Fatalf("read pubkey: %v", err)
	}
	if string(got) != "ssh-rsa AAAAG /home/x/.ssh/id_rsa\n" {
		t.Errorf("pubkey = %q, want the single agent key", got)
	}
}

func TestRunAgentMatchByBasename(t *testing.T) {
	e := newTestEnv(t)
	e.s.agentLines = []string{"ssh-a AAA /home/x/.ssh/id_match", "ssh-b BBB /other/thing"}
	e.write(t, ".ssh/config", "IdentityFile ~/.ssh/id_match\n")
	e.run(t)

	got, err := os.ReadFile(filepath.Join(e.dst, "id_match.pub"))
	if err != nil {
		t.Fatalf("read pubkey: %v", err)
	}
	if string(got) != "ssh-a AAA /home/x/.ssh/id_match\n" {
		t.Errorf("pubkey = %q, want the agent line naming the identity", got)
	}
}

func TestRunAgentAmbiguousWarns(t *testing.T) {
	e := newTestEnv(t)
	e.s.agentLines = []string{"ssh-a AAA one", "ssh-b BBB two"}
	e.write(t, ".ssh/config", "IdentityFile ~/.ssh/id_x\n")
	e.run(t)

	if exists(filepath.Join(e.dst, "id_x.pub")) {
		t.Error("expected no pubkey for ambiguous agent match")
	}
	if w := e.errb.String(); !bytes.Contains(e.errb.Bytes(), []byte("no unambiguous agent key")) || !bytes.Contains(e.errb.Bytes(), []byte("id_x")) {
		t.Errorf("warnings = %q, want an unambiguous-agent-key warning for id_x", w)
	}
}

func TestRunNoPubNoAgentWarns(t *testing.T) {
	e := newTestEnv(t)
	e.write(t, ".ssh/config", "IdentityFile ~/.ssh/id_none\n")
	e.run(t)

	if exists(filepath.Join(e.dst, "id_none.pub")) {
		t.Error("expected no pubkey when neither .pub nor agent provides one")
	}
	if !bytes.Contains(e.errb.Bytes(), []byte("no public key for")) || !bytes.Contains(e.errb.Bytes(), []byte("agent empty")) {
		t.Errorf("warnings = %q, want a no-public-key warning", e.errb.String())
	}
}

func TestRunOutsideIdentityMasked(t *testing.T) {
	e := newTestEnv(t)
	e.write(t, ".ssh/config", "IdentityFile /etc/ssh/global_key\n")
	e.run(t)

	if got := e.out.String(); got != "/etc/ssh/global_key\n" {
		t.Errorf("mask output = %q, want the out-of-tree key path", got)
	}
	if exists(filepath.Join(e.dst, "etc/ssh/global_key.pub")) {
		t.Error("an out-of-tree identity must not be materialized in the tree")
	}
}

// TestRunIncludeContainment is the security-relevant case: an Include that climbs
// out of ~/.ssh is read (its directives still parsed) but never copied into the
// tree, so a crafted Include cannot cause a write outside the workspace.
func TestRunIncludeContainment(t *testing.T) {
	e := newTestEnv(t)
	e.write(t, ".ssh/config", "Include ../outside.conf\n")
	e.write(t, "outside.conf", "IdentityFile /outside/priv\n")
	e.run(t)

	if exists(filepath.Join(e.dst, "outside.conf")) {
		t.Error("an Include outside ~/.ssh must not be copied into the tree")
	}
	// Proves the outside config was still read (added to cfgs) — its IdentityFile
	// directive was parsed and the out-of-tree key surfaced for masking.
	if got := e.out.String(); got != "/outside/priv\n" {
		t.Errorf("mask output = %q, want /outside/priv from the included file", got)
	}
}

func TestRunCapTruncates(t *testing.T) {
	e := newTestEnv(t)
	e.write(t, ".ssh/config", "Include conf.d/*.conf\n")
	for i := 0; i < 70; i++ {
		e.write(t, filepath.Join(".ssh/conf.d", pad(i)+".conf"), "# c\n")
	}
	e.run(t)

	copied, err := filepath.Glob(filepath.Join(e.dst, "conf.d", "*.conf"))
	if err != nil {
		t.Fatalf("glob: %v", err)
	}
	// 64 total configs allowed; the root config is one, so at most 63 includes.
	if len(copied) != maxConfigs-1 {
		t.Errorf("copied %d include files, want %d", len(copied), maxConfigs-1)
	}
	if !bytes.Contains(e.errb.Bytes(), []byte("more than 64 ssh config files")) {
		t.Errorf("warnings = %q, want a truncation warning", e.errb.String())
	}
}

func pad(i int) string {
	const digits = "0123456789"
	return string([]byte{'f', digits[i/10], digits[i%10]})
}

// Command claude-ssh-sanitize builds a sanitized copy of ~/.ssh for the
// bubblewrap namespace in claude-sandbox.bash: ~/.ssh/config and everything it
// Includes from inside ~/.ssh, known_hosts, and one public key per IdentityFile
// — but never a private key. ssh still authenticates through the agent socket
// (re-bound into the namespace by the launcher), so the sanitized tree needs
// only public material.
//
// It replaces the shell that walked Include directives with sed and a hand-rolled
// quote-aware tokenizer. That logic — glob/dedup/containment/cap on Includes, and
// IdentityFile→public-key resolution with the agent-listing fallback — was the
// launcher's other untested hotspot, and the containment check (an Include like
// `../../../x` must not cause a copy outside the workspace) is security-relevant.
//
// Usage: claude-ssh-sanitize --home DIR --src ~/.ssh --dst DEST [--auth-sock S]
//
// It writes the sanitized tree at --dst, prints to stdout the path of any private
// key that lies OUTSIDE ~/.ssh (one per line, which the launcher masks over the
// read-only root), and prints human warnings to stderr. A non-zero exit means the
// tree could not be built; the launcher treats that as fatal rather than exposing
// the real ~/.ssh. See sources/.config/shell/scripts/claude-sandbox.bash.
package main

import (
	"bufio"
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
)

// maxConfigs caps how many config files (root + Includes) are copied, so a
// pathological Include fan-out cannot make the walk unbounded.
const maxConfigs = 64

// splitTokens splits an ssh_config argument list into tokens, honouring the
// double quotes ssh uses around paths that contain spaces. It mirrors the shell
// __cs_split it replaces: a quote toggles quoting and is dropped; space and tab
// delimit only outside quotes; everything else accumulates. An unterminated quote
// simply runs to end of line.
func splitTokens(line string) []string {
	var out []string
	var tok strings.Builder
	quoted := false
	for i := 0; i < len(line); i++ {
		ch := line[i]
		switch {
		case ch == '"':
			quoted = !quoted
		case (ch == ' ' || ch == '\t') && !quoted:
			if tok.Len() > 0 {
				out = append(out, tok.String())
				tok.Reset()
			}
		default:
			tok.WriteByte(ch)
		}
	}
	if tok.Len() > 0 {
		out = append(out, tok.String())
	}
	return out
}

// directiveArgs returns the argument text of an ssh_config line whose keyword
// matches (case-insensitively), or ok=false otherwise. It mirrors the sed
// `s/^[[:space:]]*KEYWORD[[:space:]=]+//p`: leading whitespace is skipped, the
// keyword must be followed by at least one separator (space, tab or `=`), and the
// remainder is returned verbatim (no trailing trim, matching the shell).
func directiveArgs(line, keyword string) (string, bool) {
	t := strings.TrimLeft(line, " \t\r\f\v")
	if len(t) < len(keyword) || !strings.EqualFold(t[:len(keyword)], keyword) {
		return "", false
	}
	rest := t[len(keyword):]
	i := 0
	for i < len(rest) && isSeparator(rest[i]) {
		i++
	}
	if i == 0 {
		return "", false
	}
	return rest[i:], true
}

func isSeparator(b byte) bool {
	return b == ' ' || b == '\t' || b == '=' || b == '\r' || b == '\f' || b == '\v'
}

// expandIncludeToken resolves an Include token as ssh does: ~/ against home, an
// absolute path unchanged, anything else against ~/.ssh. Paths are not cleaned
// here — the glob and the later EvalSymlinks handle `..`, exactly as the shell
// left resolution to the filesystem.
func expandIncludeToken(tok, home, sshDir string) string {
	switch {
	case strings.HasPrefix(tok, "~/"):
		return home + "/" + tok[2:]
	case strings.HasPrefix(tok, "/"):
		return tok
	default:
		return sshDir + "/" + tok
	}
}

// expandIdentityToken resolves an IdentityFile token. Unlike Include, a token
// that is neither ~/ nor absolute (a %-token or a bare name) is not resolvable
// here and is skipped (ok=false).
func expandIdentityToken(tok, home string) (string, bool) {
	switch {
	case strings.HasPrefix(tok, "~/"):
		return home + "/" + tok[2:], true
	case strings.HasPrefix(tok, "/"):
		return tok, true
	default:
		return "", false
	}
}

// sanitizer holds the inputs and accumulated state for building the sanitized
// tree. out receives mask targets (stdout); errW receives warnings (stderr).
type sanitizer struct {
	home     string // value of $HOME
	srcDir   string // the real ~/.ssh passed in (e.g. $HOME/.ssh)
	dstDir   string // where the sanitized tree is built
	sshReal  string // EvalSymlinks(srcDir): canonical, for Include containment
	dotSSH   string // filepath.Join(home, ".ssh"): literal, for IdentityFile/socket tests
	authSock string // value of $SSH_AUTH_SOCK (may be empty)

	agentLines []string // non-empty lines of `ssh-add -L`

	out  io.Writer
	errW io.Writer

	seen  map[string]bool // canonical config paths already walked
	cfgs  []string        // config files to scan for IdentityFile, in discovery order
	trunc bool
}

func (s *sanitizer) mask(path string) { _, _ = fmt.Fprintln(s.out, path) }

func (s *sanitizer) warn(format string, a ...any) {
	_, _ = fmt.Fprintf(s.errW, "claude-sandbox: "+format+"\n", a...)
}

// run builds the whole sanitized tree.
func (s *sanitizer) run() error {
	if err := os.MkdirAll(s.dstDir, 0o700); err != nil {
		return fmt.Errorf("create dst: %w", err)
	}
	for _, f := range []string{"known_hosts", "known_hosts2"} {
		src := filepath.Join(s.srcDir, f)
		if fi, err := os.Stat(src); err == nil && fi.Mode().IsRegular() {
			if err := copyFile(src, filepath.Join(s.dstDir, f)); err != nil {
				return fmt.Errorf("copy %s: %w", f, err)
			}
		}
	}
	if err := s.walkIncludes(); err != nil {
		return err
	}
	if s.trunc {
		s.warn("more than %d ssh config files reachable from ~/.ssh/config; the remainder were not copied, so ssh may resolve some hosts differently inside the sandbox", maxConfigs)
	}
	if err := s.resolveIdentities(); err != nil {
		return err
	}
	return s.socketMountpoint()
}

// walkIncludes copies ~/.ssh/config, then breadth-first follows its Include
// directives, copying every reachable config that lies under ~/.ssh and
// recording all of them (in-tree or not) for the IdentityFile scan.
func (s *sanitizer) walkIncludes() error {
	configPath := filepath.Join(s.srcDir, "config")
	if fi, err := os.Stat(configPath); err != nil || !fi.Mode().IsRegular() {
		return nil
	}
	if err := copyFile(configPath, filepath.Join(s.dstDir, "config")); err != nil {
		return fmt.Errorf("copy config: %w", err)
	}
	real, err := filepath.EvalSymlinks(configPath)
	if err != nil {
		return fmt.Errorf("resolve config: %w", err)
	}
	s.seen[real] = true
	s.cfgs = append(s.cfgs, configPath)

	queue := []string{configPath}
	for len(queue) > 0 {
		cur := queue[0]
		queue = queue[1:]
		reals, err := s.includeTargets(cur)
		if err != nil {
			return err
		}
		for _, r := range reals {
			if s.seen[r] {
				continue
			}
			s.seen[r] = true
			// Cap checked before copying: an over-long list truncates rather than
			// copying unbounded files, and the remainder is reported once.
			if len(s.cfgs) >= maxConfigs {
				s.trunc = true
				continue
			}
			if err := s.copyIfUnderSSH(r); err != nil {
				return err
			}
			s.cfgs = append(s.cfgs, r)
			queue = append(queue, r)
		}
	}
	return nil
}

// includeTargets reads cfgPath and returns the canonical paths of the regular
// files its Include directives resolve to (after ~-expansion, globbing and
// symlink resolution). Dedup, the cap and copying are the caller's job.
func (s *sanitizer) includeTargets(cfgPath string) ([]string, error) {
	f, err := os.Open(cfgPath)
	if err != nil {
		return nil, fmt.Errorf("open %s: %w", cfgPath, err)
	}
	defer func() { _ = f.Close() }()

	var reals []string
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	for sc.Scan() {
		args, ok := directiveArgs(sc.Text(), "include")
		if !ok {
			continue
		}
		for _, tok := range splitTokens(args) {
			// Glob returns existing matches for a meta pattern, or the literal
			// path when it exists and has no meta — so it doubles as the `[ -f ]`
			// existence gate. A malformed pattern yields no matches, like an
			// unmatched glob left literal in the shell.
			matches, _ := filepath.Glob(expandIncludeToken(tok, s.home, s.srcDir))
			for _, m := range matches {
				if fi, err := os.Stat(m); err != nil || !fi.Mode().IsRegular() {
					continue
				}
				real, err := filepath.EvalSymlinks(m)
				if err != nil {
					continue
				}
				reals = append(reals, real)
			}
		}
	}
	return reals, sc.Err()
}

// copyIfUnderSSH copies real into the sanitized tree at its path relative to
// ~/.ssh, but only when it actually lies under the canonical ~/.ssh. A target
// outside (an absolute Include, or one that climbed out via `..`) stays readable
// through the read-only root and is not copied — the containment check that keeps
// a crafted Include from writing outside the workspace.
func (s *sanitizer) copyIfUnderSSH(real string) error {
	prefix := s.sshReal + string(os.PathSeparator)
	if !strings.HasPrefix(real+string(os.PathSeparator), prefix) {
		return nil
	}
	rel := strings.TrimPrefix(real, prefix)
	return copyFile(real, filepath.Join(s.dstDir, rel))
}

// resolveIdentities materializes one public key per IdentityFile found across the
// collected configs, and emits (to stdout) the private keys that lie outside
// ~/.ssh so the launcher can mask them.
func (s *sanitizer) resolveIdentities() error {
	if len(s.cfgs) == 0 {
		return nil
	}
	prefix := s.dotSSH + string(os.PathSeparator)
	for _, raw := range s.collectIdentityFiles() {
		id, ok := expandIdentityToken(raw, s.home)
		if !ok {
			continue
		}
		if !strings.HasPrefix(id, prefix) {
			// Outside ~/.ssh: the private key would stay readable through the
			// read-only root — mask it. Its real .pub (if any) stays visible, so
			// agent auth for that host keeps working.
			s.mask(id)
			continue
		}
		dstPub := filepath.Join(s.dstDir, strings.TrimPrefix(id, prefix)) + ".pub"
		if _, err := os.Stat(dstPub); err == nil {
			continue
		}
		if err := s.writePubkey(id, dstPub); err != nil {
			return err
		}
	}
	return nil
}

// collectIdentityFiles returns the sorted, de-duplicated IdentityFile values
// across every collected config, with surrounding double quotes stripped —
// mirroring `sed … | sed 's/^"//; s/"$//' | sort -u`.
func (s *sanitizer) collectIdentityFiles() []string {
	set := make(map[string]bool)
	for _, cfg := range s.cfgs {
		f, err := os.Open(cfg)
		if err != nil {
			continue
		}
		sc := bufio.NewScanner(f)
		sc.Buffer(make([]byte, 0, 64*1024), 1024*1024)
		for sc.Scan() {
			v, ok := directiveArgs(sc.Text(), "identityfile")
			if !ok {
				continue
			}
			v = strings.TrimSuffix(strings.TrimPrefix(v, "\""), "\"")
			if v != "" {
				set[v] = true
			}
		}
		_ = f.Close()
	}
	out := make([]string, 0, len(set))
	for k := range set {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

// writePubkey materializes the public key for an in-tree identity: the .pub
// beside the key if present, else the agent listing when it is the only key or
// its comment unambiguously names this identity. Otherwise it warns and writes
// nothing (ssh falls back to the agent for that host).
func (s *sanitizer) writePubkey(id, dstPub string) error {
	if fi, err := os.Stat(id + ".pub"); err == nil && fi.Mode().IsRegular() {
		return copyFile(id+".pub", dstPub)
	}
	switch len(s.agentLines) {
	case 0:
		s.warn("no public key for %s (no .pub beside it, agent empty); ssh with this identity cannot work this session — create the .pub or ssh-add before launching", id)
		return nil
	case 1:
		return writeString(dstPub, s.agentLines[0]+"\n")
	default:
		base := filepath.Base(id)
		var matches []string
		for _, ln := range s.agentLines {
			if strings.Contains(ln, base) {
				matches = append(matches, ln)
			}
		}
		if len(matches) == 1 {
			return writeString(dstPub, matches[0]+"\n")
		}
		s.warn("no unambiguous agent key for %s (no .pub beside it, %d agent keys); skipping", id, len(s.agentLines))
		return nil
	}
}

// socketMountpoint creates an empty file in the sanitized tree where the agent
// socket lives under ~/.ssh, so the launcher's read-only bind of the tree does
// not hide the mountpoint the socket re-bind needs.
func (s *sanitizer) socketMountpoint() error {
	prefix := s.dotSSH + string(os.PathSeparator)
	if s.authSock == "" || !strings.HasPrefix(s.authSock, prefix) {
		return nil
	}
	dst := filepath.Join(s.dstDir, strings.TrimPrefix(s.authSock, prefix))
	if err := os.MkdirAll(filepath.Dir(dst), 0o700); err != nil {
		return err
	}
	f, err := os.OpenFile(dst, os.O_CREATE|os.O_WRONLY, 0o600)
	if err != nil {
		return err
	}
	return f.Close()
}

// copyFile copies src to dst (creating dst's parent), at 0o600 — the launcher
// runs under umask 077, and only public material lands here anyway.
func copyFile(src, dst string) error {
	data, err := os.ReadFile(src)
	if err != nil {
		return err
	}
	return writeBytes(dst, data)
}

func writeString(dst, content string) error { return writeBytes(dst, []byte(content)) }

func writeBytes(dst string, data []byte) error {
	if err := os.MkdirAll(filepath.Dir(dst), 0o700); err != nil {
		return err
	}
	return os.WriteFile(dst, data, 0o600)
}

func main() {
	home := flag.String("home", "", "value of $HOME")
	src := flag.String("src", "", "path to the real ~/.ssh directory")
	dst := flag.String("dst", "", "destination directory for the sanitized tree")
	authSock := flag.String("auth-sock", "", "value of $SSH_AUTH_SOCK (optional)")
	flag.Parse()

	if *home == "" || *src == "" || *dst == "" {
		fmt.Fprintln(os.Stderr, "claude-ssh-sanitize: --home, --src and --dst are required")
		os.Exit(2)
	}

	sshReal, err := filepath.EvalSymlinks(*src)
	if err != nil {
		fmt.Fprintf(os.Stderr, "claude-ssh-sanitize: resolve %s: %v\n", *src, err)
		os.Exit(1)
	}

	// The agent listing feeds the .pub fallback; a missing/empty agent is routine
	// (the repo agent runs `ssh-agent -t 2h`), so its error is intentionally dropped.
	agent, _ := exec.Command("ssh-add", "-L").Output()
	var agentLines []string
	for _, ln := range strings.Split(string(agent), "\n") {
		if ln != "" {
			agentLines = append(agentLines, ln)
		}
	}

	s := &sanitizer{
		home:       *home,
		srcDir:     *src,
		dstDir:     *dst,
		sshReal:    sshReal,
		dotSSH:     filepath.Join(*home, ".ssh"),
		authSock:   *authSock,
		agentLines: agentLines,
		out:        os.Stdout,
		errW:       os.Stderr,
		seen:       make(map[string]bool),
	}
	if err := s.run(); err != nil {
		fmt.Fprintf(os.Stderr, "claude-ssh-sanitize: %v\n", err)
		os.Exit(1)
	}
}

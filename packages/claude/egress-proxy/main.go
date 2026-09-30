// Command claude-egress-proxy is the network filter behind the credential
// sessions of claude-sandbox.bash (CLAUDE_SANDBOX_ALLOW_JIRA / _FIREBASE, the
// `cj` and `cf` leader aliases). Those sessions get no network of their own
// (bwrap --unshare-net): everything they send goes through this proxy, which
// runs on the host and lets through only the hosts the launcher lists. It is
// the shape Anthropic's sandbox-runtime uses on Linux, without the parts this
// launcher does not need (SOCKS, TLS termination, credential injection).
//
//	claude-egress-proxy serve --socket PATH [--parent PID] --allow PATTERN...
//
// Host side: an HTTP proxy on a unix socket, CONNECT for HTTPS and
// absolute-URI requests for plain HTTP. A request reaches its upstream only
// when its host matches an --allow pattern and the address it is dialled at is
// public: a listed name that resolves to loopback, a private or link-local
// range, cloud metadata or one of this host's own addresses is refused, so
// whoever controls a listed name's DNS cannot turn it into a way back to the
// host or the LAN. A refusal gets a 403 saying how to allow the host, and a
// line on stderr. Exits when --parent does: the launcher passes its own PID,
// which becomes bwrap's.
//
//	claude-egress-proxy bridge [--listen ADDR] --socket PATH -- COMMAND [ARG...]
//
// Namespace side: binds ADDR (the namespace's own loopback), hands the
// listener to a background copy of itself that relays each connection to the
// unix socket, then execs COMMAND. The relay is listening before COMMAND's
// first request, and COMMAND keeps this process's PID.
//
// Patterns: "example.com" (that host), "*.example.com" (any subdomain, not the
// apex), "*" (any host), each with an optional ":port". An IP literal is
// matched only by the same literal, and a request for one that is listed
// skips the address check: listing it is an explicit choice.
package main

import (
	"bufio"
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/netip"
	"os"
	"os/exec"
	"os/signal"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

const usage = `usage:
  claude-egress-proxy serve --socket PATH [--parent PID] --allow PATTERN...
  claude-egress-proxy bridge [--listen ADDR] --socket PATH -- COMMAND [ARG...]`

// pattern is one --allow entry, normalised: lower-case, no trailing dot, an
// IPv6 literal without brackets.
type pattern struct {
	host string // "*", "*.domain", a host name, or an IP literal
	port int    // 0 matches any port
}

func parsePattern(s string) (pattern, error) {
	h := strings.ToLower(strings.TrimSpace(s))
	port := 0
	if strings.HasPrefix(h, "[") {
		end := strings.IndexByte(h, ']')
		if end < 0 {
			return pattern{}, fmt.Errorf("%q: unclosed [", s)
		}
		if rest := h[end+1:]; rest != "" {
			p, err := parsePort(strings.TrimPrefix(rest, ":"))
			if err != nil || !strings.HasPrefix(rest, ":") {
				return pattern{}, fmt.Errorf("%q: bad port", s)
			}
			port = p
		}
		h = h[1:end]
		if a, err := netip.ParseAddr(h); err != nil || !a.Is6() {
			return pattern{}, fmt.Errorf("%q: not an IPv6 address", s)
		}
		return pattern{host: h, port: port}, nil
	}
	if strings.Count(h, ":") > 1 {
		return pattern{}, fmt.Errorf("%q: bracket an IPv6 address, as in [::1]:443", s)
	}
	if i := strings.IndexByte(h, ':'); i >= 0 {
		p, err := parsePort(h[i+1:])
		if err != nil {
			return pattern{}, fmt.Errorf("%q: bad port", s)
		}
		h, port = h[:i], p
	}
	h = strings.TrimSuffix(h, ".")
	if h != "*" && !validName(strings.TrimPrefix(h, "*.")) {
		return pattern{}, fmt.Errorf("%q: not a host name, *.domain or *", s)
	}
	return pattern{host: h, port: port}, nil
}

func parsePort(s string) (int, error) {
	p, err := strconv.Atoi(s)
	if err != nil || p < 1 || p > 65535 {
		return 0, fmt.Errorf("bad port %q", s)
	}
	return p, nil
}

func validName(s string) bool {
	if s == "" || len(s) > 253 {
		return false
	}
	for _, label := range strings.Split(s, ".") {
		if label == "" || len(label) > 63 {
			return false
		}
		for _, r := range label {
			if !nameChar(r) {
				return false
			}
		}
	}
	return true
}

func nameChar(r rune) bool {
	return r >= 'a' && r <= 'z' || r >= '0' && r <= '9' || r == '-' || r == '_'
}

// matches reports whether p admits host:port; host is normalised the same way.
func (p pattern) matches(host string, port int) bool {
	if p.port != 0 && p.port != port {
		return false
	}
	switch {
	case p.host == "*":
		return true
	case strings.HasPrefix(p.host, "*."):
		return strings.HasSuffix(host, p.host[1:])
	}
	if a, err := netip.ParseAddr(p.host); err == nil {
		b, err := netip.ParseAddr(host)
		return err == nil && a.Unmap() == b.Unmap()
	}
	return host == p.host
}

func normHost(h string) string {
	return strings.TrimSuffix(strings.ToLower(h), ".")
}

var (
	cgnat   = netip.MustParsePrefix("100.64.0.0/10")
	thisNet = netip.MustParsePrefix("0.0.0.0/8")
	nat64   = netip.MustParsePrefix("64:ff9b::/96")
	sixTo4  = netip.MustParsePrefix("2002::/16")
	// Instance-metadata endpoints outside the ranges below (169.254.169.254
	// is link-local, AWS's fd00:ec2::254 private).
	metadataAddrs = []netip.Addr{
		netip.MustParseAddr("168.63.129.16"), // Azure
		netip.MustParseAddr("192.0.0.192"),   // Oracle Cloud
	}
)

// publicAddr reports whether the proxy may dial a for a listed name: not
// loopback, private, link-local, multicast, CGNAT, unspecified, broadcast,
// cloud metadata, or one of local (this host's own addresses). IPv6 forms that
// carry an IPv4 address (mapped, NAT64, 6to4) are judged by that address.
func publicAddr(a netip.Addr, local map[netip.Addr]bool) bool {
	a = a.Unmap()
	if a.Is6() {
		b := a.As16()
		switch {
		case nat64.Contains(a):
			return publicAddr(netip.AddrFrom4([4]byte(b[12:16])), local)
		case sixTo4.Contains(a):
			return publicAddr(netip.AddrFrom4([4]byte(b[2:6])), local)
		}
	}
	if !a.IsValid() || a.IsLoopback() || a.IsUnspecified() || a.IsPrivate() ||
		a.IsLinkLocalUnicast() || a.IsLinkLocalMulticast() ||
		a.IsInterfaceLocalMulticast() || a.IsMulticast() ||
		cgnat.Contains(a) || thisNet.Contains(a) ||
		a == netip.AddrFrom4([4]byte{255, 255, 255, 255}) || local[a] {
		return false
	}
	for _, m := range metadataAddrs {
		if a == m {
			return false
		}
	}
	return true
}

// localAddrs lists this host's interface addresses. Read per request: a VPN
// or a new lease can add one while a session runs.
func localAddrs() map[netip.Addr]bool {
	m := map[netip.Addr]bool{}
	addrs, _ := net.InterfaceAddrs()
	for _, a := range addrs {
		if n, ok := a.(*net.IPNet); ok {
			if ip, ok := netip.AddrFromSlice(n.IP); ok {
				m[ip.Unmap()] = true
			}
		}
	}
	return m
}

type proxy struct {
	allow   []pattern
	resolve func(ctx context.Context, host string) ([]netip.Addr, error)
	addrOK  func(netip.Addr) bool
	dial    func(ctx context.Context, addr string) (net.Conn, error)
	log     io.Writer
}

func newProxy(allow []pattern, log io.Writer) *proxy {
	d := &net.Dialer{Timeout: 15 * time.Second}
	return &proxy{
		allow: allow,
		resolve: func(ctx context.Context, host string) ([]netip.Addr, error) {
			return net.DefaultResolver.LookupNetIP(ctx, "ip", host)
		},
		addrOK: func(a netip.Addr) bool { return publicAddr(a, localAddrs()) },
		dial: func(ctx context.Context, addr string) (net.Conn, error) {
			return d.DialContext(ctx, "tcp", addr)
		},
		log: log,
	}
}

// denial is a request the policy refuses (403), unlike an upstream that
// could not be reached (502).
type denial struct{ reason string }

func (d denial) Error() string { return d.reason }

// open connects to host:port if the policy admits it.
func (p *proxy) open(ctx context.Context, host string, port int) (net.Conn, error) {
	listed, literal := false, false
	ip, ipErr := netip.ParseAddr(host)
	for _, pat := range p.allow {
		if !pat.matches(host, port) {
			continue
		}
		listed = true
		if ipErr == nil && pat.host != "*" {
			literal = true
		}
	}
	if !listed {
		return nil, denial{"not on this session's network allowlist"}
	}
	addrs := []netip.Addr{ip}
	if ipErr != nil {
		var err error
		if addrs, err = p.resolve(ctx, host); err != nil {
			return nil, fmt.Errorf("resolve %s: %w", host, err)
		}
	}
	var ok []netip.Addr
	for _, a := range addrs {
		if literal || p.addrOK(a) {
			ok = append(ok, a.Unmap())
		}
	}
	if len(ok) == 0 {
		return nil, denial{"resolves only to loopback, private, link-local or this host's own addresses"}
	}
	var last error
	for _, a := range ok {
		c, err := p.dial(ctx, netip.AddrPortFrom(a, uint16(port)).String())
		if err == nil {
			return c, nil
		}
		last = err
	}
	return nil, last
}

func (p *proxy) serveConn(c net.Conn) {
	defer func() { _ = c.Close() }()
	_ = c.SetReadDeadline(time.Now().Add(30 * time.Second))
	br := bufio.NewReader(c)
	req, err := http.ReadRequest(br)
	if err != nil {
		return
	}
	_ = c.SetReadDeadline(time.Time{})
	// Bounds the resolve and the dial only: an established connection
	// outlives it.
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	if req.Method != http.MethodConnect {
		p.forward(ctx, c, req)
		return
	}
	host, portStr, err := net.SplitHostPort(req.Host)
	port, perr := parsePort(portStr)
	if err != nil || perr != nil {
		reply(c, http.StatusBadRequest, "claude-sandbox: CONNECT needs host:port\n")
		return
	}
	host = normHost(host)
	up, err := p.open(ctx, host, port)
	if err != nil {
		p.refuse(c, host, port, err)
		return
	}
	defer func() { _ = up.Close() }()
	if _, err := io.WriteString(c, "HTTP/1.1 200 Connection Established\r\n\r\n"); err != nil {
		return
	}
	// Anything the client sent right behind the CONNECT line is already in br.
	if n := br.Buffered(); n > 0 {
		b, _ := br.Peek(n)
		if _, err := up.Write(b); err != nil {
			return
		}
	}
	relay(c, up)
}

// forward handles a plain-HTTP request in absolute form, one per connection.
func (p *proxy) forward(ctx context.Context, c net.Conn, req *http.Request) {
	if req.URL.Scheme != "http" || req.URL.Host == "" {
		reply(c, http.StatusBadRequest, "claude-sandbox: this proxy takes CONNECT, or absolute http:// requests\n")
		return
	}
	host, port := normHost(req.URL.Hostname()), 80
	if s := req.URL.Port(); s != "" {
		var err error
		if port, err = parsePort(s); err != nil {
			reply(c, http.StatusBadRequest, "claude-sandbox: bad port\n")
			return
		}
	}
	up, err := p.open(ctx, host, port)
	if err != nil {
		p.refuse(c, host, port, err)
		return
	}
	defer func() { _ = up.Close() }()
	req.Header.Del("Proxy-Connection")
	req.Header.Del("Proxy-Authorization")
	req.Close = true
	if err := req.Write(up); err != nil {
		return
	}
	_, _ = io.Copy(c, up)
}

func (p *proxy) refuse(c net.Conn, host string, port int, err error) {
	target := net.JoinHostPort(host, strconv.Itoa(port))
	now := time.Now().Format(time.RFC3339)
	var d denial
	if errors.As(err, &d) {
		_, _ = fmt.Fprintf(p.log, "%s denied %s: %s\n", now, target, d.reason)
		reply(c, http.StatusForbidden, fmt.Sprintf(
			"claude-sandbox: %s is blocked, %s. This session's network is filtered (cf/cj); relaunch with CLAUDE_SANDBOX_NET_ALLOW=%s to let it through.\n",
			target, d.reason, host))
		return
	}
	_, _ = fmt.Fprintf(p.log, "%s failed %s: %v\n", now, target, err)
	reply(c, http.StatusBadGateway, fmt.Sprintf("claude-sandbox: could not reach %s: %v\n", target, err))
}

func reply(w io.Writer, code int, body string) {
	extra := ""
	if code == http.StatusForbidden {
		extra = "X-Proxy-Error: blocked-by-claude-sandbox\r\n"
	}
	_, _ = fmt.Fprintf(w, "HTTP/1.1 %d %s\r\nContent-Type: text/plain; charset=utf-8\r\n%sConnection: close\r\nContent-Length: %d\r\n\r\n%s",
		code, http.StatusText(code), extra, len(body), body)
}

// relay copies both ways until both directions are done, passing each EOF on
// as a half-close so request/response protocols finish cleanly.
func relay(a, b net.Conn) {
	var wg sync.WaitGroup
	wg.Add(2)
	pipe := func(dst, src net.Conn) {
		defer wg.Done()
		_, _ = io.Copy(dst, src)
		if cw, ok := dst.(interface{ CloseWrite() error }); ok {
			_ = cw.CloseWrite()
		} else {
			_ = dst.Close()
		}
	}
	go pipe(a, b)
	go pipe(b, a)
	wg.Wait()
}

// acceptLoop serves ln until it is closed.
func acceptLoop(ln net.Listener, handle func(net.Conn)) error {
	for {
		c, err := ln.Accept()
		if err != nil {
			if errors.Is(err, net.ErrClosed) {
				return nil
			}
			time.Sleep(50 * time.Millisecond)
			continue
		}
		go handle(c)
	}
}

func serve(args []string, stderr io.Writer) error {
	fs := flag.NewFlagSet("serve", flag.ContinueOnError)
	fs.SetOutput(stderr)
	socket := fs.String("socket", "", "unix socket to listen on")
	parent := fs.Int("parent", 0, "exit when this PID exits")
	var allow []pattern
	fs.Func("allow", "host pattern to let through (repeatable)", func(s string) error {
		p, err := parsePattern(s)
		if err == nil {
			allow = append(allow, p)
		}
		return err
	})
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *socket == "" || fs.NArg() > 0 {
		return errors.New("serve: takes --socket, --parent and --allow only")
	}
	ln, err := net.Listen("unix", *socket)
	if err != nil {
		return err
	}
	if err := os.Chmod(*socket, 0o600); err != nil {
		_ = ln.Close()
		return err
	}
	// The launcher starts this in the pane's process group: a job-control
	// signal must not take the filter down under a live session. It goes when
	// the session does (--parent), or on SIGTERM.
	signal.Ignore(syscall.SIGHUP, syscall.SIGINT, syscall.SIGQUIT)
	term := make(chan os.Signal, 1)
	signal.Notify(term, syscall.SIGTERM)
	go func() {
		<-term
		_ = ln.Close()
	}()
	if *parent > 0 {
		go func() {
			// EPERM means the PID now belongs to another user: ours is gone.
			for syscall.Kill(*parent, 0) == nil {
				time.Sleep(500 * time.Millisecond)
			}
			_ = ln.Close()
		}()
	}
	return acceptLoop(ln, newProxy(allow, stderr).serveConn)
}

func bridge(args []string, stderr io.Writer) error {
	fs := flag.NewFlagSet("bridge", flag.ContinueOnError)
	fs.SetOutput(stderr)
	listen := fs.String("listen", "127.0.0.1:3128", "TCP address to relay from")
	socket := fs.String("socket", "", "unix socket of the host-side proxy")
	if err := fs.Parse(args); err != nil {
		return err
	}
	cmd := fs.Args()
	if *socket == "" || len(cmd) == 0 {
		return errors.New("bridge: needs --socket and a command after --")
	}
	path, err := exec.LookPath(cmd[0])
	if err != nil {
		return err
	}
	ln, err := net.Listen("tcp", *listen)
	if err != nil {
		return err
	}
	f, err := ln.(*net.TCPListener).File()
	_ = ln.Close()
	if err != nil {
		return err
	}
	self, err := os.Executable()
	if err != nil {
		return err
	}
	r := exec.Command(self, "relay", "--socket", *socket)
	r.ExtraFiles = []*os.File{f} // fd 3 in the relay
	if err := r.Start(); err != nil {
		return err
	}
	_ = f.Close()
	return syscall.Exec(path, cmd, os.Environ())
}

// relayMain is bridge's background half: it serves the listener inherited on
// fd 3 until the namespace goes away with the command.
func relayMain(args []string, stderr io.Writer) error {
	fs := flag.NewFlagSet("relay", flag.ContinueOnError)
	fs.SetOutput(stderr)
	socket := fs.String("socket", "", "unix socket of the host-side proxy")
	if err := fs.Parse(args); err != nil {
		return err
	}
	// Same process group as the command: its job-control signals are not ours.
	signal.Ignore(syscall.SIGHUP, syscall.SIGINT, syscall.SIGQUIT, syscall.SIGTSTP)
	ln, err := net.FileListener(os.NewFile(3, "listener"))
	if err != nil {
		return err
	}
	return relayServe(ln, *socket)
}

func relayServe(ln net.Listener, socket string) error {
	return acceptLoop(ln, func(c net.Conn) {
		defer func() { _ = c.Close() }()
		u, err := net.Dial("unix", socket)
		if err != nil {
			return
		}
		defer func() { _ = u.Close() }()
		relay(c, u)
	})
}

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, usage)
		os.Exit(2)
	}
	var err error
	switch os.Args[1] {
	case "serve":
		err = serve(os.Args[2:], os.Stderr)
	case "bridge":
		err = bridge(os.Args[2:], os.Stderr)
	case "relay":
		err = relayMain(os.Args[2:], os.Stderr)
	default:
		fmt.Fprintln(os.Stderr, usage)
		os.Exit(2)
	}
	if err != nil {
		fmt.Fprintf(os.Stderr, "claude-egress-proxy: %v\n", err)
		os.Exit(1)
	}
}

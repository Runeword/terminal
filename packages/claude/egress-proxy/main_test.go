package main

import (
	"bufio"
	"context"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"net/url"
	"path/filepath"
	"strings"
	"testing"
)

func TestParsePattern(t *testing.T) {
	tests := []struct {
		in   string
		want pattern
		ok   bool
	}{
		{"Example.COM.", pattern{"example.com", 0}, true},
		{"*.github.com", pattern{"*.github.com", 0}, true},
		{"api.example.com:443", pattern{"api.example.com", 443}, true},
		{"*", pattern{"*", 0}, true},
		{"*:22", pattern{"*", 22}, true},
		{"[::1]:8080", pattern{"::1", 8080}, true},
		{"1.2.3.4", pattern{"1.2.3.4", 0}, true},
		{"2001:db8::1", pattern{}, false},
		{"exa mple.com", pattern{}, false},
		{"*example.com", pattern{}, false},
		{"a.*.com", pattern{}, false},
		{"example..com", pattern{}, false},
		{"example.com:0", pattern{}, false},
		{"example.com:http", pattern{}, false},
		{"", pattern{}, false},
		{"[::1", pattern{}, false},
		{"[1.2.3.4]", pattern{}, false},
	}
	for _, tt := range tests {
		got, err := parsePattern(tt.in)
		if (err == nil) != tt.ok || got != tt.want {
			t.Errorf("parsePattern(%q) = %+v, %v; want %+v, ok=%v", tt.in, got, err, tt.want, tt.ok)
		}
	}
}

func TestMatches(t *testing.T) {
	tests := []struct {
		pat, host string
		port      int
		want      bool
	}{
		{"example.com", "example.com", 443, true},
		{"example.com", "www.example.com", 443, false},
		{"*.example.com", "a.b.example.com", 443, true},
		{"*.example.com", "example.com", 443, false},
		{"*.example.com", "badexample.com", 443, false},
		{"example.com:443", "example.com", 80, false},
		{"*", "anything.test", 22, true},
		{"1.2.3.4", "1.2.3.4", 443, true},
		{"1.2.3.4", "1.2.3.5", 443, false},
		{"[::1]:8080", "::1", 8080, true},
	}
	for _, tt := range tests {
		p, err := parsePattern(tt.pat)
		if err != nil {
			t.Fatal(err)
		}
		if got := p.matches(tt.host, tt.port); got != tt.want {
			t.Errorf("%q matches %s:%d = %v, want %v", tt.pat, tt.host, tt.port, got, tt.want)
		}
	}
}

func TestPublicAddr(t *testing.T) {
	local := map[netip.Addr]bool{netip.MustParseAddr("203.0.113.9"): true}
	tests := []struct {
		addr string
		want bool
	}{
		{"8.8.8.8", true},
		{"2606:4700:4700::1111", true},
		{"64:ff9b::808:808", true}, // NAT64 of 8.8.8.8
		{"127.0.0.1", false},
		{"::1", false},
		{"::ffff:127.0.0.1", false},
		{"10.1.2.3", false},
		{"172.16.0.1", false},
		{"192.168.1.1", false},
		{"169.254.169.254", false},
		{"fe80::1", false},
		{"fd00:ec2::254", false},
		{"100.64.0.1", false},
		{"0.1.2.3", false},
		{"255.255.255.255", false},
		{"224.0.0.1", false},
		{"64:ff9b::7f00:1", false}, // NAT64 of 127.0.0.1
		{"2002:7f00:1::", false},   // 6to4 of 127.0.0.1
		{"168.63.129.16", false},
		{"203.0.113.9", false}, // one of this host's addresses
	}
	for _, tt := range tests {
		if got := publicAddr(netip.MustParseAddr(tt.addr), local); got != tt.want {
			t.Errorf("publicAddr(%s) = %v, want %v", tt.addr, got, tt.want)
		}
	}
}

// testProxy resolves every name to 127.0.0.1, where the test upstreams
// listen; addrOK decides whether that loopback answer is let through.
func testProxy(t *testing.T, addrOK func(netip.Addr) bool, allow ...string) string {
	t.Helper()
	var pats []pattern
	for _, a := range allow {
		p, err := parsePattern(a)
		if err != nil {
			t.Fatal(err)
		}
		pats = append(pats, p)
	}
	p := newProxy(pats, io.Discard)
	p.resolve = func(context.Context, string) ([]netip.Addr, error) {
		return []netip.Addr{netip.MustParseAddr("127.0.0.1")}, nil
	}
	p.addrOK = addrOK
	sock := filepath.Join(t.TempDir(), "p.sock")
	ln, err := net.Listen("unix", sock)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = ln.Close() })
	go func() { _ = acceptLoop(ln, p.serveConn) }()
	return sock
}

func echoServer(t *testing.T) int {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = ln.Close() })
	go func() {
		_ = acceptLoop(ln, func(c net.Conn) {
			defer func() { _ = c.Close() }()
			_, _ = io.Copy(c, c)
		})
	}()
	return ln.Addr().(*net.TCPAddr).Port
}

func connect(t *testing.T, sock, target string) (net.Conn, *bufio.Reader, string) {
	t.Helper()
	c, err := net.Dial("unix", sock)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = c.Close() })
	_, _ = fmt.Fprintf(c, "CONNECT %s HTTP/1.1\r\nHost: %s\r\n\r\n", target, target)
	br := bufio.NewReader(c)
	status, err := br.ReadString('\n')
	if err != nil {
		t.Fatal(err)
	}
	return c, br, status
}

func TestConnect(t *testing.T) {
	port := echoServer(t)
	always := func(netip.Addr) bool { return true }
	public := func(a netip.Addr) bool { return publicAddr(a, nil) }

	t.Run("listed host is relayed", func(t *testing.T) {
		sock := testProxy(t, always, "*.allowed.test")
		c, br, status := connect(t, sock, fmt.Sprintf("api.allowed.test:%d", port))
		if !strings.HasPrefix(status, "HTTP/1.1 200") {
			t.Fatalf("status %q", status)
		}
		if _, err := br.ReadString('\n'); err != nil { // blank line ending the reply
			t.Fatal(err)
		}
		_, _ = fmt.Fprint(c, "ping\n")
		if got, _ := br.ReadString('\n'); got != "ping\n" {
			t.Fatalf("echo %q", got)
		}
	})

	t.Run("unlisted host is refused", func(t *testing.T) {
		sock := testProxy(t, always, "*.allowed.test")
		_, br, status := connect(t, sock, "evil.test:443")
		if !strings.HasPrefix(status, "HTTP/1.1 403") {
			t.Fatalf("status %q", status)
		}
		rest, _ := io.ReadAll(br)
		for _, want := range []string{"X-Proxy-Error: blocked-by-claude-sandbox", "not on this session's network allowlist", "CLAUDE_SANDBOX_NET_ALLOW=evil.test"} {
			if !strings.Contains(string(rest), want) {
				t.Errorf("reply lacks %q:\n%s", want, rest)
			}
		}
	})

	t.Run("listed host resolving to loopback is refused", func(t *testing.T) {
		sock := testProxy(t, public, "rebind.test")
		_, br, status := connect(t, sock, fmt.Sprintf("rebind.test:%d", port))
		if !strings.HasPrefix(status, "HTTP/1.1 403") {
			t.Fatalf("status %q", status)
		}
		if rest, _ := io.ReadAll(br); !strings.Contains(string(rest), "loopback") {
			t.Errorf("reply lacks the reason:\n%s", rest)
		}
	})

	t.Run("listed IP literal skips the address check", func(t *testing.T) {
		sock := testProxy(t, public, fmt.Sprintf("127.0.0.1:%d", port))
		_, _, status := connect(t, sock, fmt.Sprintf("127.0.0.1:%d", port))
		if !strings.HasPrefix(status, "HTTP/1.1 200") {
			t.Fatalf("status %q", status)
		}
	})
}

func TestForward(t *testing.T) {
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = fmt.Fprintf(w, "ok %s", r.URL.Path)
	}))
	defer up.Close()
	port := up.Listener.Addr().(*net.TCPAddr).Port
	sock := testProxy(t, func(netip.Addr) bool { return true }, "allowed.test")
	client := &http.Client{Transport: &http.Transport{
		Proxy: http.ProxyURL(&url.URL{Scheme: "http", Host: "proxy.invalid"}),
		DialContext: func(context.Context, string, string) (net.Conn, error) {
			return net.Dial("unix", sock)
		},
	}}

	resp, err := client.Get(fmt.Sprintf("http://allowed.test:%d/x", port))
	if err != nil {
		t.Fatal(err)
	}
	body, _ := io.ReadAll(resp.Body)
	_ = resp.Body.Close()
	if resp.StatusCode != 200 || string(body) != "ok /x" {
		t.Fatalf("allowed: %d %q", resp.StatusCode, body)
	}

	resp, err = client.Get("http://evil.test/")
	if err != nil {
		t.Fatal(err)
	}
	_ = resp.Body.Close()
	if resp.StatusCode != http.StatusForbidden {
		t.Fatalf("unlisted: %d", resp.StatusCode)
	}
}

func TestRelay(t *testing.T) {
	sock := filepath.Join(t.TempDir(), "echo.sock")
	echo, err := net.Listen("unix", sock)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = echo.Close() }()
	go func() {
		_ = acceptLoop(echo, func(c net.Conn) {
			defer func() { _ = c.Close() }()
			_, _ = io.Copy(c, c)
		})
	}()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = ln.Close() }()
	go func() { _ = relayServe(ln, sock) }()

	c, err := net.Dial("tcp", ln.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = c.Close() }()
	_, _ = fmt.Fprint(c, "ping\n")
	if got, _ := bufio.NewReader(c).ReadString('\n'); got != "ping\n" {
		t.Fatalf("relay echo %q", got)
	}
}

func TestBridgeNeedsACommand(t *testing.T) {
	if err := bridge([]string{"--socket", "/nonexistent"}, io.Discard); err == nil {
		t.Fatal("bridge without a command succeeded")
	}
}

//go:build android

// Android has no /etc/resolv.conf, and this binary is built CGO-free, so Go's
// pure resolver finds no nameserver and falls back to [::1]:53 — where nothing
// listens, so every lookup fails "connection refused". (curl works because it
// goes through Android's own resolver, which Go cannot reach without cgo.) So
// point Go's resolver at real servers: whatever Android has configured
// (getprop net.dnsN) when that is set, else public resolvers that answer
// inside mainland China without a VPN.
package main

import (
	"context"
	"net"
	"os/exec"
	"strings"
	"time"
)

func init() {
	servers := androidDNSServers()
	if len(servers) == 0 {
		// AliDNS, DNSPod, then Cloudflare — the first two work without a VPN in CN.
		servers = []string{"223.5.5.5:53", "119.29.29.29:53", "1.1.1.1:53"}
	}
	net.DefaultResolver = &net.Resolver{
		PreferGo: true,
		Dial: func(ctx context.Context, _, _ string) (net.Conn, error) {
			d := net.Dialer{Timeout: 5 * time.Second}
			var err error
			for _, s := range servers {
				c, e := d.DialContext(ctx, "udp", s)
				if e == nil {
					return c, nil
				}
				err = e
			}
			return nil, err
		},
	}
}

// androidDNSServers reads the nameservers Android holds in system properties.
// Often empty on Android 8+ (private DNS), hence the public fallback above.
func androidDNSServers() []string {
	var out []string
	for _, prop := range []string{"net.dns1", "net.dns2"} {
		b, err := exec.Command("getprop", prop).Output()
		if err != nil {
			continue
		}
		if ip := strings.TrimSpace(string(b)); net.ParseIP(ip) != nil {
			out = append(out, net.JoinHostPort(ip, "53"))
		}
	}
	return out
}

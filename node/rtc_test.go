package main

import (
	"strings"
	"testing"
)

func TestPredictPorts(t *testing.T) {
	sym := "v=0\r\nm=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\n" +
		"a=candidate:1 1 udp 2130706431 192.168.31.103 50000 typ host\r\n" +
		"a=candidate:2 1 udp 1694498815 112.94.214.61 1893 typ srflx raddr 0.0.0.0 rport 50001\r\n" +
		"a=candidate:3 1 udp 1694498815 112.94.214.61 1897 typ srflx raddr 0.0.0.0 rport 50002\r\n" +
		"a=end-of-candidates\r\n"
	got := predictPorts(sym, 3)
	for _, p := range []string{" 1898 ", " 1899 ", " 1900 "} {
		if !strings.Contains(got, "112.94.214.61"+p+"typ srflx") {
			t.Fatalf("missing guess%s:\n%s", p, got)
		}
	}
	if strings.Contains(got, " 1901 ") || !strings.HasSuffix(got, "a=end-of-candidates\r\n") {
		t.Fatalf("bad answer:\n%s", got)
	}
	if strings.Index(got, "pp3") > strings.Index(got, "end-of-candidates") {
		t.Fatal("guesses after end-of-candidates")
	}
	cone := strings.ReplaceAll(sym, " 1897 ", " 1893 ")
	if predictPorts(cone, 3) != cone {
		t.Fatal("added guesses for a NAT that keeps ports")
	}
}

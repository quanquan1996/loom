//go:build !windows

package main

import (
	"encoding/base64"
	"net"
	"testing"
)

func TestForwardRelaysBothWays(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	go func() { // echoes, uppercased, then hangs up
		c, err := ln.Accept()
		if err != nil {
			return
		}
		buf := make([]byte, 64)
		n, _ := c.Read(buf)
		for i := range buf[:n] {
			buf[i] -= 32
		}
		c.Write(buf[:n])
		c.Close()
	}()
	port := ln.Addr().(*net.TCPAddr).Port

	s, out := testSession(t)
	s.cfg.ForwardPorts = []int{port}
	s.forwardOpen(request{ID: "f1", Port: port})
	if p := next(t, out); p.event != "forward_opened" {
		t.Fatalf("first push %q, want forward_opened", p.event)
	}
	s.forwardInput(request{ID: "f1", Data: base64.StdEncoding.EncodeToString([]byte("hello"))})
	p := next(t, out)
	got, _ := base64.StdEncoding.DecodeString(p.payload["data"].(string))
	if p.event != "forward_out" || string(got) != "HELLO" {
		t.Fatalf("got %q %q, want forward_out HELLO", p.event, got)
	}
	if p := next(t, out); p.event != "forward_closed" {
		t.Fatalf("after hang-up %q, want forward_closed", p.event)
	}
}

func TestForwardRefusesPortsNotAllowed(t *testing.T) {
	s, out := testSession(t)
	// Unset: only 5900.
	if !s.forwardAllowed(5900) || s.forwardAllowed(22) {
		t.Fatal("default must be 5900 alone")
	}
	s.forwardOpen(request{ID: "f2", Port: 22})
	if p := next(t, out); p.event != "error" {
		t.Fatalf("got %q, want error", p.event)
	}
	// [] turns it off altogether.
	s.cfg.ForwardPorts = []int{}
	if s.forwardAllowed(5900) {
		t.Fatal("[] must allow nothing")
	}
}

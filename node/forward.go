package main

import (
	"encoding/base64"
	"fmt"
	"log"
	"net"
	"slices"
	"strconv"
	"sync"
	"time"
)

// Port forwarding: the bytes of one TCP connection to a port on this device's
// own loopback, relayed both ways — what loom's VNC pane rides on (noVNC in the
// browser speaks the protocol; loom and this daemon only pass bytes, the way
// websockify does).
//
//	loom → device: forward_open {id, port}, forward_in {id, data}, cancel {id}
//	device → loom: forward_opened {id}, forward_out {id, data}, forward_closed {id}, error {id, message}
//
// Loom names the port; this device decides whether it may: only 127.0.0.1,
// never another machine, and only a port in config's forward_ports — 5900
// (VNC) when that is unset, nothing when it is []. So a loom that is not to be
// trusted still reaches no more than the owner of the device allowed. Like a
// terminal, a forward ends with the connection.
var defaultForwardPorts = []int{5900}

func (s *session) forwardAllowed(port int) bool {
	ports := s.cfg.ForwardPorts
	if ports == nil {
		ports = defaultForwardPorts
	}
	return port > 0 && slices.Contains(ports, port)
}

// Input waiting for the local port. A VNC client's mouse moves and keys are
// small; a server that stops reading for this long is stuck, and the
// connection is closed rather than bytes dropped, which would corrupt it.
const forwardInputQueue = 1024

type forward struct {
	c    net.Conn
	in   chan []byte
	once sync.Once
}

func (d *forward) close() {
	d.once.Do(func() {
		close(d.in)
		d.c.Close()
	})
}

func (s *session) forwardOpen(r request) {
	if !s.forwardAllowed(r.Port) {
		s.fail(r.ID, fmt.Errorf("port %d is not forwarded on this device (forward_ports in its loom-node config)", r.Port))
		return
	}
	addr := net.JoinHostPort("127.0.0.1", strconv.Itoa(r.Port))
	c, err := net.DialTimeout("tcp", addr, 5*time.Second)
	if err != nil {
		s.fail(r.ID, err)
		return
	}
	if tc, ok := c.(*net.TCPConn); ok {
		tc.SetNoDelay(true)
	}

	d := &forward{c: c, in: make(chan []byte, forwardInputQueue)}
	s.mu.Lock()
	s.forwards[r.ID] = d
	s.mu.Unlock()
	audit("forward %s open %s", r.ID, addr)
	s.c.push(s.ctx, "forward_opened", map[string]any{"id": r.ID})

	s.wg.Add(1)
	go func() {
		defer s.wg.Done()
		for data := range d.in {
			if _, err := c.Write(data); err != nil {
				c.Close()
				return
			}
		}
	}()

	s.wg.Add(1)
	go func() {
		defer s.wg.Done()
		buf := make([]byte, outChunk)
		for {
			n, err := c.Read(buf)
			if n > 0 {
				if s.c.push(s.ctx, "forward_out", map[string]any{
					"id": r.ID, "data": base64.StdEncoding.EncodeToString(buf[:n]),
				}) != nil {
					break
				}
			}
			if err != nil {
				break
			}
		}
		s.mu.Lock()
		delete(s.forwards, r.ID)
		s.mu.Unlock()
		d.close()
		audit("forward %s closed", r.ID)
		s.c.push(s.ctx, "forward_closed", map[string]any{"id": r.ID})
	}()
}

func (s *session) forwardInput(r request) {
	data, err := base64.StdEncoding.DecodeString(r.Data)
	if err != nil {
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	d := s.forwards[r.ID]
	if d == nil {
		return
	}
	select {
	case d.in <- data:
	default:
		log.Printf("forward %s: the local port is not reading; closing", r.ID)
		delete(s.forwards, r.ID)
		d.close()
	}
}

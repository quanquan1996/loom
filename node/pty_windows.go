//go:build windows

package main

import "errors"

// Terminals need a Unix PTY (creack/pty); on Windows a ConPTY port is still to
// come, so a request to open one fails at once and the session says why.
type term struct{}

func (t *term) kill() {}

func (s *session) ptyOpen(r request) {
	s.fail(r.ID, errors.New("terminals are not supported on Windows devices yet"))
}

func (s *session) ptyInput(r request)  {}
func (s *session) ptyResize(r request) {}

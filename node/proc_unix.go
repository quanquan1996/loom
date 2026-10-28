//go:build !windows

package main

import (
	"errors"
	"os"
	"os/exec"
	"syscall"
	"time"
)

// The user's login shell, unless install was told otherwise.
func defaultShell() string {
	if s := os.Getenv("SHELL"); s != "" {
		return s
	}
	return "/bin/sh"
}

// shellCommand runs a command the way the user would type it: `$SHELL -lc`,
// in a process group of its own so a kill reaches everything it started.
func shellCommand(shell, command string) *exec.Cmd {
	cmd := exec.Command(shell, "-lc", command)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	return cmd
}

// group is a started command and whatever it forks.
type group struct{ pgid int }

func newGroup(cmd *exec.Cmd) *group { return &group{pgid: cmd.Process.Pid} }

// kill asks politely, then not.
func (g *group) kill() {
	syscall.Kill(-g.pgid, syscall.SIGTERM)
	time.AfterFunc(killGrace, func() { syscall.Kill(-g.pgid, syscall.SIGKILL) })
}

func (g *group) close() {}

// exitCode is the shell's, or 128 + the signal that ended it, as a shell would
// report it.
func exitCode(ps *os.ProcessState) int {
	if ws, ok := ps.Sys().(syscall.WaitStatus); ok && ws.Signaled() {
		return 128 + int(ws.Signal())
	}
	return ps.ExitCode()
}

// detach starts the daemon outside the installing terminal's session.
func detach(cmd *exec.Cmd) {
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
}

func daemonLog() {}

func installWindows(string) error { return errors.New("not windows") }

func uninstallWindows() {}

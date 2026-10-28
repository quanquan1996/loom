package main

import (
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"

	"golang.org/x/sys/windows"
)

// PowerShell 7 if it is there, else the Windows PowerShell every Windows has.
func defaultShell() string {
	if p, err := exec.LookPath("pwsh.exe"); err == nil {
		return p
	}
	return "powershell.exe"
}

// Ahead of every PowerShell command: UTF-8 out, whatever the console's code
// page (936 on a Chinese Windows), and no progress bars, which nobody sees
// and which make Invoke-WebRequest crawl.
const psPrelude = "$ProgressPreference='SilentlyContinue'\n" +
	"[Console]::OutputEncoding=$OutputEncoding=New-Object System.Text.UTF8Encoding $false\n"

// shellCommand runs a command in PowerShell, cmd or — for a Git Bash or MSYS
// shell given to install — `-lc`, like everywhere else.
//
// The daemon has no console (see guiCopy), so each command gets a console of
// its own, hidden: without one, every command would open a window; and
// [Console]::OutputEncoding and chcp need one to set.
func shellCommand(shell, command string) *exec.Cmd {
	var cmd *exec.Cmd
	attr := &syscall.SysProcAttr{CreationFlags: windows.CREATE_NO_WINDOW | windows.CREATE_NEW_PROCESS_GROUP}

	switch strings.ToLower(strings.TrimSuffix(filepath.Base(shell), filepath.Ext(shell))) {
	case "powershell", "pwsh":
		// -Command, not -EncodedCommand: Windows PowerShell writes errors from
		// an encoded command to a redirected stderr as CLIXML. Go quotes the
		// one argument by the rules PowerShell parses it with.
		cmd = exec.Command(shell, "-NoLogo", "-NoProfile", "-NonInteractive",
			"-ExecutionPolicy", "Bypass", "-Command", psPrelude+command)
	case "cmd":
		// cmd parses its own command line, so it is handed one verbatim.
		cmd = exec.Command(shell)
		attr.CmdLine = `"` + shell + `" /d /s /c "chcp 65001 >nul & ` + command + `"`
	default:
		cmd = exec.Command(shell, "-lc", command)
	}
	cmd.SysProcAttr = attr
	return cmd
}

// group is a job object holding the command and whatever it starts: Windows
// has no process groups to signal, and a child outlives its parent's kill.
type group struct {
	job  windows.Handle
	proc *os.Process
}

func newGroup(cmd *exec.Cmd) *group {
	g := &group{proc: cmd.Process}
	job, err := windows.CreateJobObject(nil, nil)
	if err != nil {
		log.Printf("no job object, so a kill reaches only the shell: %v", err)
		return g
	}
	h, err := windows.OpenProcess(windows.PROCESS_SET_QUOTA|windows.PROCESS_TERMINATE, false, uint32(cmd.Process.Pid))
	if err == nil {
		err = windows.AssignProcessToJobObject(job, h)
		windows.CloseHandle(h)
	}
	if err != nil {
		log.Printf("cannot put pid %d in a job, so a kill reaches only the shell: %v", cmd.Process.Pid, err)
		windows.CloseHandle(job)
		return g
	}
	g.job = job
	return g
}

// kill ends everything at once. A console program cannot be asked to stop
// short of Ctrl-C, which only reaches a console's own processes. 143 is what a
// shell reports for SIGTERM.
func (g *group) kill() {
	if g.job != 0 && windows.TerminateJobObject(g.job, 143) == nil {
		return
	}
	g.proc.Kill()
}

// close lets go of the job without ending it: as with `cmd &` on Unix, what a
// command left running in the background keeps running.
func (g *group) close() {
	if g.job != 0 {
		windows.CloseHandle(g.job)
	}
}

func exitCode(ps *os.ProcessState) int { return ps.ExitCode() }

// detach starts the daemon with nothing tying it to the installing terminal,
// out of the terminal's job if it has one.
func detach(cmd *exec.Cmd) {
	cmd.SysProcAttr = &syscall.SysProcAttr{
		CreationFlags: windows.CREATE_NEW_PROCESS_GROUP | windows.DETACHED_PROCESS | windows.CREATE_BREAKAWAY_FROM_JOB,
	}
}

// daemonLog points the daemon's log at a file when it runs with no console,
// as it does once installed, and stderr goes nowhere.
func daemonLog() {
	if h, err := windows.GetStdHandle(windows.STD_ERROR_HANDLE); err == nil && h != 0 && h != windows.InvalidHandle {
		return
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return
	}
	dir := filepath.Join(home, ".local", "state", "loom-node")
	os.MkdirAll(dir, 0o700)
	path := filepath.Join(dir, "daemon.log")
	if st, err := os.Stat(path); err == nil && st.Size() > 5<<20 {
		os.Rename(path, path+".1")
	}
	if f, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600); err == nil {
		log.SetOutput(f)
	}
}

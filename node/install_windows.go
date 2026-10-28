package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"time"

	"golang.org/x/sys/windows/registry"
)

// On Windows the daemon starts at logon from the user's Run key — per user,
// no administrator, like a launchd agent — and runs as loom-noded.exe: this
// binary with its PE header marked as a GUI program, so Windows gives it no
// console window, neither at logon nor in Windows Terminal.

const (
	runKey    = `Software\Microsoft\Windows\CurrentVersion\Run`
	runValue  = "loom-node"
	daemonExe = "loom-noded.exe"
)

func installWindows(exe string) error {
	daemon := filepath.Join(filepath.Dir(exe), daemonExe)
	stopDaemon()

	b, err := os.ReadFile(exe)
	if err != nil {
		return err
	}
	if err := guiCopy(b); err != nil {
		return err
	}
	tmp := daemon + ".tmp"
	if err := os.WriteFile(tmp, b, 0o755); err != nil {
		return err
	}
	// The old daemon may take a moment to let go of its file.
	for i := 0; ; i++ {
		if err = os.Rename(tmp, daemon); err == nil || i == 20 {
			break
		}
		time.Sleep(100 * time.Millisecond)
	}
	if err != nil {
		os.Remove(tmp)
		return err
	}

	k, _, err := registry.CreateKey(registry.CURRENT_USER, runKey, registry.SET_VALUE)
	if err != nil {
		return err
	}
	defer k.Close()
	if err := k.SetStringValue(runValue, `"`+daemon+`" daemon`); err != nil {
		return err
	}

	cmd := exec.Command(daemon, "daemon")
	detach(cmd)
	if err := cmd.Start(); err != nil {
		// A terminal whose job forbids breaking away.
		cmd = exec.Command(daemon, "daemon")
		if err = cmd.Start(); err != nil {
			return err
		}
	}
	cmd.Process.Release()

	fmt.Println("installed", daemon, `— starts at logon (HKCU\`+runKey+`), logs in ~\.local\state\loom-node\daemon.log`)
	return nil
}

func uninstallWindows() {
	stopDaemon()
	if k, err := registry.OpenKey(registry.CURRENT_USER, runKey, registry.SET_VALUE); err == nil {
		k.DeleteValue(runValue)
		k.Close()
	}
	if exe, err := os.Executable(); err == nil {
		os.Remove(filepath.Join(filepath.Dir(exe), daemonExe))
	}
}

func stopDaemon() {
	exec.Command("taskkill", "/F", "/IM", daemonExe).Run()
}

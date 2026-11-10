package main

import (
	"io"
	"log"
	"os"
	"path/filepath"
	"runtime/debug"
)

// logOut receives app and libgm logs: stderr plus ~/.cache/GoobMessages/goob.log (Linux) or
// %LocalAppData%\GoobMessages\goob.log (Windows), appended to (rotated to goob.log.old past 4 MB). Crash traces (Go panics and
// fatal signals, including ones in C code) are written to the same file. Never log tokens, cookies or message bodies.
var logOut io.Writer = os.Stderr

type bestEffort struct{ w io.Writer }

func (b bestEffort) Write(p []byte) (int, error) {
	_, _ = b.w.Write(p)
	return len(p), nil
}

func setupLogFile() {
	base, err := os.UserCacheDir()
	if err != nil {
		return
	}
	dir := filepath.Join(base, "GoobMessages")
	if os.MkdirAll(dir, 0o700) != nil {
		return
	}
	// Append (never truncate): a second launch only signals the running instance and exits, and must not wipe the
	// running instance's log. Rotate once it gets big.
	path := filepath.Join(dir, "goob.log")
	if st, err := os.Stat(path); err == nil && st.Size() > 4<<20 {
		_ = os.Rename(path, path+".old")
	}
	f, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		return
	}
	// The file comes first and stderr errors are ignored: launched from a desktop menu, stderr may be closed, and
	// io.MultiWriter stops at the first failing writer.
	logOut = io.MultiWriter(f, bestEffort{os.Stderr})
	log.SetOutput(logOut)
	_ = debug.SetCrashOutput(f, debug.CrashOptions{})
}

package main

import (
	"os"

	"github.com/wailsapp/wails/v2/pkg/runtime"
)

// trayHandle is the platform tray icon (tray_linux.go: StatusNotifierItem over D-Bus; tray_windows.go:
// Shell_NotifyIcon). With a tray, closing the window keeps the app running there.
type trayHandle interface {
	SetUnread(n int)
	Close()
}

type noTray struct{}

func (noTray) SetUnread(int) {}
func (noTray) Close()        {}

// startHidden: launched with --hidden (e.g. at login) the app starts in the tray without showing the window.
var startHidden = func() bool {
	for _, a := range os.Args[1:] {
		if a == "--hidden" || a == "--background" {
			return true
		}
	}
	return false
}()

func (a *App) showWindow() {
	runtime.WindowShow(a.ctx)
	runtime.WindowUnminimise(a.ctx)
}

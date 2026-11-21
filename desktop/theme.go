package main

import (
	"os"
	"time"

	"github.com/goobmessages/desktop/internal/storage"
	"github.com/wailsapp/wails/v2/pkg/runtime"
)

// maxThemeBytes caps the user stylesheet; a theme only needs to set a few dozen color variables.
const maxThemeBytes = 256 << 10

// UserThemeCSS returns the user's theme.css (see docs in the README), or "" when there is none.
func (a *App) UserThemeCSS() string {
	css, _ := readTheme()
	return css
}

func readTheme() (string, time.Time) {
	p, err := storage.ThemePath()
	if err != nil {
		return "", time.Time{}
	}
	st, err := os.Stat(p)
	if err != nil || !st.Mode().IsRegular() || st.Size() > maxThemeBytes {
		return "", time.Time{}
	}
	b, err := os.ReadFile(p)
	if err != nil {
		return "", time.Time{}
	}
	return string(b), st.ModTime()
}

// watchTheme re-sends theme.css to the UI when it changes, so a new wallpaper (matugen run) recolors the app live.
// Polling a single stat every 2 s is cheaper and more portable than a file watcher.
func (a *App) watchTheme() {
	_, last := readTheme()
	for !a.quit.Load() {
		time.Sleep(2 * time.Second)
		css, mod := readTheme()
		if mod.Equal(last) {
			continue
		}
		last = mod
		runtime.EventsEmit(a.ctx, "theme", css)
	}
}

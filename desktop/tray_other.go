//go:build !linux && !windows

package main

func startTray(a *App) trayHandle { return noTray{} }

package main

// appVersion is stamped by the release workflow (-ldflags "-X main.appVersion=1.2.3"); local builds say "dev".
var appVersion = "dev"

// Version is shown in Settings.
func (a *App) Version() string { return appVersion }

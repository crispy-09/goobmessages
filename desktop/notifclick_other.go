//go:build !linux

package main

func startNotifClickWatcher() {}

// notificationWasClicked: only Linux needs the dismissal check (see notifclick_linux.go).
func notificationWasClicked() bool { return true }

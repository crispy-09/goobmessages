//go:build linux

package main

import (
	"sync"
	"time"

	"github.com/godbus/dbus/v5"
)

// Wails reports a notification the user dismissed (or that the notification daemon closed with reason 2, which
// some shells use when a banner times out) exactly like a click on it: both arrive as the default action. Raising
// the window for a dismissal steals focus, and on tiling compositors (Hyprland, Sway) it also switches workspace.
// So we watch the D-Bus ActionInvoked signal ourselves: a real click sends the "default" action key first.
var notifClicks struct {
	sync.Mutex
	last time.Time
	cond *sync.Cond
}

func startNotifClickWatcher() {
	notifClicks.cond = sync.NewCond(&notifClicks.Mutex)
	conn, err := dbus.ConnectSessionBus()
	if err != nil {
		return
	}
	if err := conn.AddMatchSignal(dbus.WithMatchInterface("org.freedesktop.Notifications"), dbus.WithMatchMember("ActionInvoked")); err != nil {
		conn.Close()
		return
	}
	ch := make(chan *dbus.Signal, 16)
	conn.Signal(ch)
	go func() {
		for sig := range ch {
			if len(sig.Body) < 2 {
				continue
			}
			if action, _ := sig.Body[1].(string); action == "default" {
				notifClicks.Lock()
				notifClicks.last = time.Now()
				notifClicks.cond.Broadcast()
				notifClicks.Unlock()
			}
		}
	}()
}

// notificationWasClicked reports whether the default-action response being handled came from a real click,
// waiting briefly because Wails may see the signal on its own D-Bus connection before we do.
func notificationWasClicked() bool {
	if notifClicks.cond == nil {
		return true // watcher unavailable: keep the old behaviour
	}
	deadline := time.Now().Add(700 * time.Millisecond)
	timer := time.AfterFunc(700*time.Millisecond, func() {
		notifClicks.Lock()
		notifClicks.cond.Broadcast()
		notifClicks.Unlock()
	})
	defer timer.Stop()
	notifClicks.Lock()
	defer notifClicks.Unlock()
	for {
		if time.Since(notifClicks.last) < 2*time.Second {
			notifClicks.last = time.Time{} // consume it: one click raises the window once
			return true
		}
		if time.Now().After(deadline) {
			return false
		}
		notifClicks.cond.Wait()
	}
}

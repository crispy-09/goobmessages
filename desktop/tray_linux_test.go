//go:build linux

package main

import (
	"os"
	"testing"

	"github.com/godbus/dbus/v5"
	"github.com/rs/zerolog"
)

// Talks to the real session bus, so it only runs with GOOB_TRAY_TEST=1.
func TestTrayOverDBus(t *testing.T) {
	if os.Getenv("GOOB_TRAY_TEST") != "1" {
		t.Skip("set GOOB_TRAY_TEST=1 to run against the session bus")
	}
	a := &App{log: zerolog.Nop()}
	tr, ok := startTray(a).(*linuxTray)
	if !ok {
		t.Fatal("tray did not start")
	}
	defer tr.Close()
	tr.SetUnread(3)

	conn, err := dbus.ConnectSessionBus()
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	item := conn.Object(tr.name, sniPath)
	for _, p := range []string{"Status", "IconPixmap", "Menu", "ToolTip", "Id"} {
		v, err := item.GetProperty(sniIface + "." + p)
		if err != nil {
			t.Fatalf("%s: %v", p, err)
		}
		t.Logf("%s: %s", p, v.Signature())
	}
	if v, _ := item.GetProperty(sniIface + ".Status"); v.Value() != "NeedsAttention" {
		t.Errorf("status %v", v.Value())
	}
	var rev uint32
	var layout menuLayout
	if err := conn.Object(tr.name, menuPath).Call(menuIface+".GetLayout", 0, int32(0), int32(-1), []string{}).Store(&rev, &layout); err != nil {
		t.Fatal(err)
	}
	if len(layout.Children) != 4 {
		t.Fatalf("menu has %d items, want 4", len(layout.Children))
	}
	if err := conn.Object(tr.name, sniPath).Call("org.freedesktop.DBus.Introspectable.Introspect", 0).Err; err != nil {
		t.Fatal(err)
	}
	// Is it registered with the tray host?
	var items []string
	if v, err := conn.Object(watcherName, watcherPath).GetProperty(watcherName + ".RegisteredStatusNotifierItems"); err == nil {
		items, _ = v.Value().([]string)
	}
	t.Logf("watcher items: %v", items)
}

//go:build linux

package main

import (
	"fmt"
	"os"
	"sync"

	"github.com/godbus/dbus/v5"
	"github.com/godbus/dbus/v5/introspect"
	"github.com/godbus/dbus/v5/prop"
)

// Linux tray icon: a StatusNotifierItem (the KDE/freedesktop tray protocol used by Quickshell/Caelestia, Waybar,
// KDE, GNOME with AppIndicator, …) with a com.canonical.dbusmenu menu. Left click shows the window; the menu has
// Open / Quit. Re-registers when the tray host (StatusNotifierWatcher) restarts, e.g. reloading the shell.

const (
	sniPath      = dbus.ObjectPath("/StatusNotifierItem")
	sniIface     = "org.kde.StatusNotifierItem"
	menuPath     = dbus.ObjectPath("/MenuBar")
	menuIface    = "com.canonical.dbusmenu"
	watcherName  = "org.kde.StatusNotifierWatcher"
	watcherPath  = dbus.ObjectPath("/StatusNotifierWatcher")
	trayItemOpen = 1
	trayItemInfo = 2
	trayItemSep  = 3
	trayItemQuit = 4
)

type sniPixmap struct {
	W, H int32
	Data []byte // ARGB32, network byte order
}

type sniToolTip struct {
	IconName string
	Pixmaps  []sniPixmap
	Title    string
	Text     string
}

type linuxTray struct {
	app   *App
	conn  *dbus.Conn
	name  string
	props *prop.Properties

	mu       sync.Mutex
	unread   int
	revision uint32
}

func startTray(a *App) trayHandle {
	conn, err := dbus.ConnectSessionBus()
	if err != nil {
		a.log.Info().Err(err).Msg("No session bus; tray icon disabled")
		return noTray{}
	}
	t := &linuxTray{app: a, conn: conn, name: fmt.Sprintf("org.kde.StatusNotifierItem-%d-1", os.Getpid()), revision: 1}
	if err := t.export(); err != nil {
		a.log.Warn().Err(err).Msg("Tray icon export failed")
		conn.Close()
		return noTray{}
	}
	if reply, err := conn.RequestName(t.name, dbus.NameFlagDoNotQueue); err != nil || reply != dbus.RequestNameReplyPrimaryOwner {
		a.log.Warn().Err(err).Msg("Tray icon name unavailable")
		conn.Close()
		return noTray{}
	}
	go t.watchHost()
	t.register()
	return t
}

func pixmaps(badge bool) []sniPixmap {
	var out []sniPixmap
	for _, size := range []int{22, 32, 48, 64} {
		img := trayIcon(size, badge)
		data := make([]byte, 0, size*size*4)
		for i := 0; i < len(img.Pix); i += 4 {
			data = append(data, img.Pix[i+3], img.Pix[i], img.Pix[i+1], img.Pix[i+2])
		}
		out = append(out, sniPixmap{W: int32(size), H: int32(size), Data: data})
	}
	return out
}

func (t *linuxTray) export() error {
	item := &sniItem{t}
	if err := t.conn.Export(item, sniPath, sniIface); err != nil {
		return err
	}
	props, err := prop.Export(t.conn, sniPath, prop.Map{sniIface: {
		"Category":            {Value: "Communications", Emit: prop.EmitTrue},
		"Id":                  {Value: "goobmessages", Emit: prop.EmitTrue},
		"Title":               {Value: "Messages", Emit: prop.EmitTrue},
		"Status":              {Value: "Active", Emit: prop.EmitTrue},
		"WindowId":            {Value: int32(0), Emit: prop.EmitTrue},
		"IconName":            {Value: "", Emit: prop.EmitTrue},
		"IconPixmap":          {Value: pixmaps(false), Emit: prop.EmitTrue},
		"OverlayIconName":     {Value: "", Emit: prop.EmitTrue},
		"OverlayIconPixmap":   {Value: []sniPixmap{}, Emit: prop.EmitTrue},
		"AttentionIconName":   {Value: "", Emit: prop.EmitTrue},
		"AttentionIconPixmap": {Value: pixmaps(true), Emit: prop.EmitTrue},
		"AttentionMovieName":  {Value: "", Emit: prop.EmitTrue},
		"ToolTip":             {Value: sniToolTip{Title: "Messages"}, Emit: prop.EmitTrue},
		"ItemIsMenu":          {Value: false, Emit: prop.EmitTrue},
		"Menu":                {Value: menuPath, Emit: prop.EmitTrue},
	}})
	if err != nil {
		return err
	}
	t.props = props

	menu := &dbusMenu{t}
	if err := t.conn.Export(menu, menuPath, menuIface); err != nil {
		return err
	}
	if _, err := prop.Export(t.conn, menuPath, prop.Map{menuIface: {
		"Version":       {Value: uint32(3)},
		"TextDirection": {Value: "ltr"},
		"Status":        {Value: "normal"},
		"IconThemePath": {Value: []string{}},
	}}); err != nil {
		return err
	}

	for path, node := range map[dbus.ObjectPath]*introspect.Node{
		sniPath: {Name: string(sniPath), Interfaces: []introspect.Interface{introspect.IntrospectData, prop.IntrospectData, {
			Name:    sniIface,
			Methods: introspect.Methods(item),
			Signals: []introspect.Signal{{Name: "NewIcon"}, {Name: "NewAttentionIcon"}, {Name: "NewOverlayIcon"},
				{Name: "NewToolTip"}, {Name: "NewTitle"}, {Name: "NewStatus", Args: []introspect.Arg{{Name: "status", Type: "s"}}}},
		}}},
		menuPath: {Name: string(menuPath), Interfaces: []introspect.Interface{introspect.IntrospectData, prop.IntrospectData, {
			Name:    menuIface,
			Methods: introspect.Methods(menu),
			Signals: []introspect.Signal{{Name: "LayoutUpdated", Args: []introspect.Arg{{Name: "revision", Type: "u"}, {Name: "parent", Type: "i"}}}},
		}}},
	} {
		if err := t.conn.Export(introspect.NewIntrospectable(node), path, "org.freedesktop.DBus.Introspectable"); err != nil {
			return err
		}
	}
	return nil
}

func (t *linuxTray) register() {
	call := t.conn.Object(watcherName, watcherPath).Call(watcherName+".RegisterStatusNotifierItem", 0, t.name)
	if call.Err != nil {
		t.app.log.Info().Err(call.Err).Msg("No tray host yet; will register when one appears")
	}
}

// watchHost re-registers whenever a StatusNotifierWatcher (re)appears on the bus.
func (t *linuxTray) watchHost() {
	if err := t.conn.AddMatchSignal(
		dbus.WithMatchInterface("org.freedesktop.DBus"),
		dbus.WithMatchMember("NameOwnerChanged"),
		dbus.WithMatchArg(0, watcherName),
	); err != nil {
		return
	}
	ch := make(chan *dbus.Signal, 8)
	t.conn.Signal(ch)
	for sig := range ch {
		if sig.Name != "org.freedesktop.DBus.NameOwnerChanged" || len(sig.Body) < 3 {
			continue
		}
		if newOwner, _ := sig.Body[2].(string); newOwner != "" {
			t.register()
		}
	}
}

func (t *linuxTray) SetUnread(n int) {
	t.mu.Lock()
	if n == t.unread {
		t.mu.Unlock()
		return
	}
	t.unread = n
	t.revision++
	rev := t.revision
	t.mu.Unlock()

	status, tip := "Active", "No unread messages"
	if n > 0 {
		status = "NeedsAttention"
		tip = fmt.Sprintf("%d unread conversation%s", n, map[bool]string{true: "", false: "s"}[n == 1])
	}
	t.props.SetMust(sniIface, "Status", status)
	t.props.SetMust(sniIface, "ToolTip", sniToolTip{Title: "Messages", Text: tip})
	// Hosts that ignore NeedsAttention still get the badge.
	t.props.SetMust(sniIface, "IconPixmap", pixmaps(n > 0))
	_ = t.conn.Emit(sniPath, sniIface+".NewStatus", status)
	_ = t.conn.Emit(sniPath, sniIface+".NewIcon")
	_ = t.conn.Emit(sniPath, sniIface+".NewToolTip")
	_ = t.conn.Emit(menuPath, menuIface+".LayoutUpdated", rev, int32(0))
}

func (t *linuxTray) Close() { t.conn.Close() }

// ---- org.kde.StatusNotifierItem methods

type sniItem struct{ t *linuxTray }

func (s *sniItem) Activate(x, y int32) *dbus.Error          { s.t.app.showWindow(); return nil }
func (s *sniItem) SecondaryActivate(x, y int32) *dbus.Error { s.t.app.showWindow(); return nil }
func (s *sniItem) ContextMenu(x, y int32) *dbus.Error       { return nil } // the host shows Menu itself
func (s *sniItem) Scroll(delta int32, orientation string) *dbus.Error {
	return nil
}

// ---- com.canonical.dbusmenu

type menuLayout struct {
	ID       int32
	Props    map[string]dbus.Variant
	Children []dbus.Variant
}

type menuEvent struct {
	ID        int32
	EventID   string
	Data      dbus.Variant
	Timestamp uint32
}

type menuItemProps struct {
	ID    int32
	Props map[string]dbus.Variant
}

type dbusMenu struct{ t *linuxTray }

func (m *dbusMenu) items() []menuItemProps {
	m.t.mu.Lock()
	n := m.t.unread
	m.t.mu.Unlock()
	v := dbus.MakeVariant
	out := []menuItemProps{{trayItemOpen, map[string]dbus.Variant{"label": v("Open Messages")}}}
	if n > 0 {
		out = append(out, menuItemProps{trayItemInfo, map[string]dbus.Variant{
			"label": v(fmt.Sprintf("%d unread", n)), "enabled": v(false)}})
	}
	return append(out,
		menuItemProps{trayItemSep, map[string]dbus.Variant{"type": v("separator")}},
		menuItemProps{trayItemQuit, map[string]dbus.Variant{"label": v("Quit")}},
	)
}

func (m *dbusMenu) GetLayout(parentID int32, depth int32, names []string) (uint32, menuLayout, *dbus.Error) {
	m.t.mu.Lock()
	rev := m.t.revision
	m.t.mu.Unlock()
	root := menuLayout{ID: 0, Props: map[string]dbus.Variant{"children-display": dbus.MakeVariant("submenu")}}
	for _, it := range m.items() {
		if parentID == it.ID {
			return rev, menuLayout{ID: it.ID, Props: it.Props, Children: []dbus.Variant{}}, nil
		}
		root.Children = append(root.Children, dbus.MakeVariant(menuLayout{ID: it.ID, Props: it.Props, Children: []dbus.Variant{}}))
	}
	if root.Children == nil {
		root.Children = []dbus.Variant{}
	}
	return rev, root, nil
}

func (m *dbusMenu) GetGroupProperties(ids []int32, names []string) ([]menuItemProps, *dbus.Error) {
	var out []menuItemProps
	for _, it := range m.items() {
		for _, id := range ids {
			if id == it.ID {
				out = append(out, it)
			}
		}
	}
	if out == nil {
		out = []menuItemProps{}
	}
	return out, nil
}

func (m *dbusMenu) GetProperty(id int32, name string) (dbus.Variant, *dbus.Error) {
	for _, it := range m.items() {
		if it.ID == id {
			if v, ok := it.Props[name]; ok {
				return v, nil
			}
		}
	}
	return dbus.MakeVariant(""), nil
}

func (m *dbusMenu) Event(id int32, eventID string, data dbus.Variant, timestamp uint32) *dbus.Error {
	if eventID != "clicked" {
		return nil
	}
	switch id {
	case trayItemOpen:
		go m.t.app.showWindow()
	case trayItemQuit:
		go m.t.app.Quit()
	}
	return nil
}

func (m *dbusMenu) EventGroup(events []menuEvent) ([]int32, *dbus.Error) {
	for _, e := range events {
		_ = m.Event(e.ID, e.EventID, e.Data, e.Timestamp)
	}
	return []int32{}, nil
}

func (m *dbusMenu) AboutToShow(id int32) (bool, *dbus.Error) { return false, nil }

func (m *dbusMenu) AboutToShowGroup(ids []int32) ([]int32, []int32, *dbus.Error) {
	return []int32{}, []int32{}, nil
}

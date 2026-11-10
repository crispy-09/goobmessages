//go:build windows

package main

import (
	"fmt"
	"runtime"
	"sync"
	"unsafe"

	"golang.org/x/sys/windows"
)

// Windows tray icon via Shell_NotifyIconW on a hidden window with its own message loop. Left click shows the
// window, right click opens Open / Quit. Re-adds itself when Explorer restarts (TaskbarCreated).

var (
	shell32                 = windows.NewLazySystemDLL("shell32.dll")
	procShellNotifyIcon     = shell32.NewProc("Shell_NotifyIconW")
	procCreatePopupMenu     = user32.NewProc("CreatePopupMenu")
	procAppendMenuW         = user32.NewProc("AppendMenuW")
	procTrackPopupMenu      = user32.NewProc("TrackPopupMenu")
	procDestroyMenu         = user32.NewProc("DestroyMenu")
	procGetCursorPos        = user32.NewProc("GetCursorPos")
	procCreateIconFromResEx = user32.NewProc("CreateIconFromResourceEx")
	procDestroyIcon         = user32.NewProc("DestroyIcon")
	procRegisterWindowMsg   = user32.NewProc("RegisterWindowMessageW")
	procGetSystemMetrics    = user32.NewProc("GetSystemMetrics")
)

const (
	nimAdd       = 0
	nimModify    = 1
	nimDelete    = 2
	nifMessage   = 1
	nifIcon      = 2
	nifTip       = 4
	wmApp        = 0x8000
	wmTrayIcon   = wmApp + 1
	wmLButtonUp  = 0x0202
	wmRButtonUp  = 0x0205
	mfString     = 0
	mfGrayed     = 1
	mfSeparator  = 0x800
	tpmReturnCmd = 0x100
	tpmRightBtn  = 0x2
	smCxSmIcon   = 49
	trayCmdOpen  = 1
	trayCmdQuit  = 2
)

type notifyIconData struct {
	CbSize           uint32
	HWnd             uintptr
	UID              uint32
	UFlags           uint32
	UCallbackMessage uint32
	HIcon            uintptr
	SzTip            [128]uint16
	DwState          uint32
	DwStateMask      uint32
	SzInfo           [256]uint16
	UVersion         uint32
	SzInfoTitle      [64]uint16
	DwInfoFlags      uint32
	GuidItem         windows.GUID
	HBalloonIcon     uintptr
}

type winTray struct {
	app            *App
	hwnd           uintptr
	taskbarCreated uintptr

	mu     sync.Mutex
	unread int
	icon   uintptr
}

var (
	theWinTray       *winTray
	trayWndProcPtr   = windows.NewCallback(trayWndProc)
	trayClassOnce    sync.Once
	trayClassName, _ = windows.UTF16PtrFromString("GoobMessagesTray")
)

func startTray(a *App) trayHandle {
	t := &winTray{app: a}
	ready := make(chan bool, 1)
	go func() {
		runtime.LockOSThread()
		defer runtime.UnlockOSThread()
		if !t.create() {
			ready <- false
			return
		}
		ready <- true
		var m winMsg
		for {
			r, _, _ := procGetMessageW.Call(uintptr(unsafe.Pointer(&m)), 0, 0, 0)
			if int32(r) <= 0 {
				break
			}
			procTranslateMessage.Call(uintptr(unsafe.Pointer(&m)))
			procDispatchMessageW.Call(uintptr(unsafe.Pointer(&m)))
		}
	}()
	if !<-ready {
		return noTray{}
	}
	return t
}

func (t *winTray) create() bool {
	var hinstance windows.Handle
	_ = windows.GetModuleHandleEx(0, nil, &hinstance)
	trayClassOnce.Do(func() {
		wc := wndClassExW{
			CbSize:        uint32(unsafe.Sizeof(wndClassExW{})),
			LpfnWndProc:   trayWndProcPtr,
			HInstance:     hinstance,
			LpszClassName: trayClassName,
		}
		procRegisterClassExW.Call(uintptr(unsafe.Pointer(&wc)))
	})
	msgName, _ := windows.UTF16PtrFromString("TaskbarCreated")
	t.taskbarCreated, _, _ = procRegisterWindowMsg.Call(uintptr(unsafe.Pointer(msgName)))
	theWinTray = t
	hwnd, _, _ := procCreateWindowExW.Call(0, uintptr(unsafe.Pointer(trayClassName)), uintptr(unsafe.Pointer(trayClassName)),
		0, 0, 0, 0, 0, 0, 0, uintptr(hinstance), 0)
	if hwnd == 0 {
		return false
	}
	t.hwnd = hwnd
	return t.notify(nimAdd)
}

func (t *winTray) makeIcon(badge bool) uintptr {
	size, _, _ := procGetSystemMetrics.Call(smCxSmIcon)
	if size == 0 {
		size = 16
	}
	data := trayIconPNG(int(size)*2, badge) // Windows scales down; 2× looks crisper on high DPI
	h, _, _ := procCreateIconFromResEx.Call(uintptr(unsafe.Pointer(&data[0])), uintptr(len(data)), 1, 0x00030000,
		size, size, 0)
	return h
}

func (t *winTray) notify(op uintptr) bool {
	t.mu.Lock()
	n := t.unread
	old := t.icon
	t.icon = t.makeIcon(n > 0)
	t.mu.Unlock()
	if old != 0 && op != nimAdd {
		defer procDestroyIcon.Call(old)
	}
	tip := "Messages"
	if n > 0 {
		tip = fmt.Sprintf("Messages: %d unread", n)
	}
	nid := notifyIconData{UID: 1, UFlags: nifMessage | nifIcon | nifTip, UCallbackMessage: wmTrayIcon, HWnd: t.hwnd, HIcon: t.icon}
	nid.CbSize = uint32(unsafe.Sizeof(nid))
	tip16, _ := windows.UTF16FromString(tip)
	copy(nid.SzTip[:len(nid.SzTip)-1], tip16)
	r, _, _ := procShellNotifyIcon.Call(op, uintptr(unsafe.Pointer(&nid)))
	return r != 0
}

func (t *winTray) SetUnread(n int) {
	t.mu.Lock()
	changed := n != t.unread
	t.unread = n
	t.mu.Unlock()
	if changed {
		t.notify(nimModify)
	}
}

func (t *winTray) Close() {
	nid := notifyIconData{HWnd: t.hwnd, UID: 1}
	nid.CbSize = uint32(unsafe.Sizeof(nid))
	procShellNotifyIcon.Call(nimDelete, uintptr(unsafe.Pointer(&nid)))
}

func (t *winTray) showMenu() {
	menu, _, _ := procCreatePopupMenu.Call()
	if menu == 0 {
		return
	}
	defer procDestroyMenu.Call(menu)
	add := func(flags, id uintptr, text string) {
		p, _ := windows.UTF16PtrFromString(text)
		procAppendMenuW.Call(menu, flags, id, uintptr(unsafe.Pointer(p)))
	}
	add(mfString, trayCmdOpen, "Open Messages")
	t.mu.Lock()
	n := t.unread
	t.mu.Unlock()
	if n > 0 {
		add(mfString|mfGrayed, 0, fmt.Sprintf("%d unread", n))
	}
	procAppendMenuW.Call(menu, mfSeparator, 0, 0)
	add(mfString, trayCmdQuit, "Quit")
	var pt struct{ X, Y int32 }
	procGetCursorPos.Call(uintptr(unsafe.Pointer(&pt)))
	procSetForeground.Call(t.hwnd) // required so the menu closes when clicking elsewhere
	cmd, _, _ := procTrackPopupMenu.Call(menu, tpmReturnCmd|tpmRightBtn, uintptr(pt.X), uintptr(pt.Y), 0, t.hwnd, 0)
	switch cmd {
	case trayCmdOpen:
		go t.app.showWindow()
	case trayCmdQuit:
		go t.app.Quit()
	}
}

func trayWndProc(hwnd, msg, wparam, lparam uintptr) uintptr {
	t := theWinTray
	switch {
	case t != nil && msg == wmTrayIcon:
		switch lparam & 0xffff {
		case wmLButtonUp:
			go t.app.showWindow()
		case wmRButtonUp:
			t.showMenu()
		}
		return 0
	case t != nil && t.taskbarCreated != 0 && msg == t.taskbarCreated:
		t.notify(nimAdd)
		return 0
	}
	r, _, _ := procDefWindowProcW.Call(hwnd, msg, wparam, lparam)
	return r
}

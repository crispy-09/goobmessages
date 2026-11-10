//go:build windows

package main

import (
	"context"
	"os"
	"runtime"
	"strings"
	"sync"
	"syscall"
	"time"
	"unsafe"

	"github.com/wailsapp/go-webview2/pkg/edge"
	"golang.org/x/sys/windows"
)

var (
	user32               = windows.NewLazySystemDLL("user32.dll")
	procRegisterClassExW = user32.NewProc("RegisterClassExW")
	procCreateWindowExW  = user32.NewProc("CreateWindowExW")
	procDefWindowProcW   = user32.NewProc("DefWindowProcW")
	procDestroyWindow    = user32.NewProc("DestroyWindow")
	procPostQuitMessage  = user32.NewProc("PostQuitMessage")
	procPostMessageW     = user32.NewProc("PostMessageW")
	procGetMessageW      = user32.NewProc("GetMessageW")
	procTranslateMessage = user32.NewProc("TranslateMessage")
	procDispatchMessageW = user32.NewProc("DispatchMessageW")
	procLoadCursorW      = user32.NewProc("LoadCursorW")
	procSetForeground    = user32.NewProc("SetForegroundWindow")
)

const (
	wmDestroy          = 0x0002
	wmSize             = 0x0005
	wmClose            = 0x0010
	wsOverlappedWindow = 0x00CF0000
	wsVisible          = 0x10000000
	cwUseDefault       = 0x80000000
	idcArrow           = 32512
)

type wndClassExW struct {
	CbSize        uint32
	Style         uint32
	LpfnWndProc   uintptr
	CbClsExtra    int32
	CbWndExtra    int32
	HInstance     windows.Handle
	HIcon         windows.Handle
	HCursor       windows.Handle
	HbrBackground windows.Handle
	LpszMenuName  *uint16
	LpszClassName *uint16
	HIconSm       windows.Handle
}

type winMsg struct {
	Hwnd    uintptr
	Message uint32
	WParam  uintptr
	LParam  uintptr
	Time    uint32
	Pt      struct{ X, Y int32 }
}

// One sign-in window at a time; the window procedure reaches its state through this.
var (
	signInMu      sync.Mutex
	signInBrowser *edge.Chromium
	wndProcPtr    = windows.NewCallback(signInWndProc)
	classOnce     sync.Once
	className, _  = windows.UTF16PtrFromString("GoobMessagesSignIn")
)

func signInWndProc(hwnd, msg, wparam, lparam uintptr) uintptr {
	switch msg {
	case wmSize:
		if signInBrowser != nil {
			signInBrowser.Resize()
		}
		return 0
	case wmClose:
		procDestroyWindow.Call(hwnd)
		return 0
	case wmDestroy:
		procPostQuitMessage.Call(0)
		return 0
	}
	r, _, _ := procDefWindowProcW.Call(hwnd, msg, wparam, lparam)
	return r
}

// googleSignIn shows Google's sign-in page and returns the account cookies.
func googleSignIn(ctx context.Context) (map[string]string, error) {
	if !signInMu.TryLock() {
		return nil, errSignInFailed
	}
	defer signInMu.Unlock()
	type result struct {
		cookies map[string]string
		err     error
	}
	done := make(chan result, 1)
	go func() {
		// WebView2 needs an STA thread with its own message loop.
		runtime.LockOSThread()
		defer runtime.UnlockOSThread()
		c, err := runSignInWindow(ctx)
		done <- result{c, err}
	}()
	r := <-done
	return r.cookies, r.err
}

func runSignInWindow(ctx context.Context) (map[string]string, error) {
	if err := windows.CoInitializeEx(0, windows.COINIT_APARTMENTTHREADED); err != nil {
		return nil, err
	}
	defer windows.CoUninitialize()

	var hinstance windows.Handle
	_ = windows.GetModuleHandleEx(0, nil, &hinstance)
	classOnce.Do(func() {
		cursor, _, _ := procLoadCursorW.Call(0, idcArrow)
		wc := wndClassExW{
			CbSize:        uint32(unsafe.Sizeof(wndClassExW{})),
			LpfnWndProc:   wndProcPtr,
			HInstance:     hinstance,
			HCursor:       windows.Handle(cursor),
			HbrBackground: windows.Handle(6), // COLOR_WINDOW + 1
			LpszClassName: className,
		}
		procRegisterClassExW.Call(uintptr(unsafe.Pointer(&wc)))
	})
	title, _ := windows.UTF16PtrFromString(signInTitle)
	hwnd, _, err := procCreateWindowExW.Call(0, uintptr(unsafe.Pointer(className)), uintptr(unsafe.Pointer(title)),
		wsOverlappedWindow|wsVisible, cwUseDefault, cwUseDefault, 520, 720, 0, 0, uintptr(hinstance), 0)
	if hwnd == 0 {
		return nil, err
	}
	procSetForeground.Call(hwnd)

	// Throwaway profile: nothing from the sign-in lingers after we copy the cookies.
	dataDir, err := os.MkdirTemp("", "goob-signin-*")
	if err != nil {
		procDestroyWindow.Call(hwnd)
		return nil, err
	}
	defer func() {
		go func() { time.Sleep(3 * time.Second); _ = os.RemoveAll(dataDir) }() // browser process lets go of it shortly
	}()

	browser := edge.NewChromium()
	browser.DataPath = dataDir
	signInBrowser = browser
	defer func() { signInBrowser = nil }()

	var cookies map[string]string
	fetching := false
	browser.NavigationCompletedCallback = func(sender *edge.ICoreWebView2, _ *edge.ICoreWebView2NavigationCompletedEventArgs) {
		src, err := sender.GetSource()
		if err != nil || !isMessagesURL(src) || fetching || cookies != nil {
			return
		}
		fetching = true
		err = getWebView2Cookies(browser, cookieURI, func(c map[string]string) {
			fetching = false
			if hasRequiredCookies(c) {
				cookies = c
				procPostMessageW.Call(hwnd, wmClose, 0, 0)
			}
		})
		if err != nil {
			fetching = false
		}
	}
	if !browser.Embed(hwnd) {
		procDestroyWindow.Call(hwnd)
		return nil, errSignInFailed
	}
	browser.Resize()
	if s, err := browser.GetSettings(); err == nil {
		_ = s.PutAreDevToolsEnabled(false)
		_ = s.PutIsStatusBarEnabled(false)
	}
	browser.Navigate(signInURL)

	stop := context.AfterFunc(ctx, func() { procPostMessageW.Call(hwnd, wmClose, 0, 0) })
	defer stop()

	var m winMsg
	for {
		r, _, _ := procGetMessageW.Call(uintptr(unsafe.Pointer(&m)), 0, 0, 0)
		if int32(r) <= 0 {
			break
		}
		procTranslateMessage.Call(uintptr(unsafe.Pointer(&m)))
		procDispatchMessageW.Call(uintptr(unsafe.Pointer(&m)))
	}
	browser.ShuttingDown()
	if cookies == nil {
		return nil, errSignInCancelled
	}
	return cookies, nil
}

// ---- ICoreWebView2CookieManager::GetCookies with a completion handler ----
// go-webview2's GetCookies wrapper treats the call as synchronous, but the real API takes an
// ICoreWebView2GetCookiesCompletedHandler and reports the list asynchronously, so we implement the handler here.

type cookiesHandlerVtbl struct {
	QueryInterface, AddRef, Release, Invoke uintptr
}

type cookiesHandler struct {
	vtbl *cookiesHandlerVtbl
}

var (
	cookiesVtbl = &cookiesHandlerVtbl{
		QueryInterface: windows.NewCallback(func(this, riid uintptr, out *uintptr) uintptr {
			*out = this
			return 0
		}),
		AddRef:  windows.NewCallback(func(this uintptr) uintptr { return 1 }),
		Release: windows.NewCallback(func(this uintptr) uintptr { return 1 }),
		Invoke: windows.NewCallback(func(this uintptr, hr uintptr, list *edge.ICoreWebView2CookieList) uintptr {
			cb := pendingCookies
			pendingCookies = nil
			if cb != nil {
				cb(readCookieList(hr, list))
			}
			return 0
		}),
	}
	cookiesHandlerObj = &cookiesHandler{vtbl: cookiesVtbl} // kept alive globally: native code holds a pointer
	pendingCookies    func(map[string]string)
)

func readCookieList(hr uintptr, list *edge.ICoreWebView2CookieList) map[string]string {
	out := map[string]string{}
	if hr != 0 || list == nil {
		return out
	}
	var b strings.Builder
	n, err := list.GetCount()
	if err != nil {
		return out
	}
	for i := uint32(0); i < n; i++ {
		c, err := list.GetItem(i)
		if err != nil || c == nil {
			continue
		}
		name, _ := c.GetName()
		value, _ := c.GetValue()
		domain, _ := c.GetDomain()
		c.Release()
		if strings.ContainsAny(name+value+domain, "\t\n") {
			continue
		}
		b.WriteString(name + "\t" + value + "\t" + domain + "\n")
	}
	out, _ = parseCookieLines(b.String())
	return out
}

func getWebView2Cookies(browser *edge.Chromium, uri string, cb func(map[string]string)) error {
	mgr, err := browser.GetCookieManager()
	if err != nil {
		return err
	}
	u, err := windows.UTF16PtrFromString(uri)
	if err != nil {
		return err
	}
	pendingCookies = cb
	// vtable: IUnknown (3), CreateCookie, CopyCookie, GetCookies => index 5.
	vtbl := *(**[8]uintptr)(unsafe.Pointer(mgr))
	hr, _, _ := syscall.SyscallN(vtbl[5], uintptr(unsafe.Pointer(mgr)), uintptr(unsafe.Pointer(u)), uintptr(unsafe.Pointer(cookiesHandlerObj)))
	if hr != 0 {
		pendingCookies = nil
		return syscall.Errno(hr)
	}
	return nil
}

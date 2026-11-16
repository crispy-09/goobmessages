//go:build linux && cgo

package main

/*
#include "webview_linux.h"
*/
import "C"

import (
	"log"
	"os"
)

func init() {
	// WebKitGTK's DMABUF renderer freezes or blanks the window with the proprietary NVIDIA driver (notably on
	// Wayland). Fall back to its shared-memory path there, unless the user chose a setting themselves. This must
	// run before GTK/WebKit start; with cgo, os.Setenv also updates the C environment the web process inherits.
	if _, set := os.LookupEnv("WEBKIT_DISABLE_DMABUF_RENDERER"); !set && hasNvidiaDriver() {
		_ = os.Setenv("WEBKIT_DISABLE_DMABUF_RENDERER", "1")
	}
}

func hasNvidiaDriver() bool {
	_, err := os.Stat("/sys/module/nvidia")
	return err == nil
}

//export goWebviewLog
func goWebviewLog(msg *C.char) { log.Printf("webview: %s", C.GoString(msg)) }

// startWebviewGuard reloads the main window's page if its web process crashes or hangs (see webview_linux.c).
func startWebviewGuard() { C.goob_webview_guard_start() }

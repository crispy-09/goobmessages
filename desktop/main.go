// GoobMessages for Linux and Windows: a Google Messages client built on mautrix libgm and Wails.
// SPDX-License-Identifier: AGPL-3.0-or-later
package main

import (
	"embed"
	"log"

	"github.com/wailsapp/wails/v2"
	"github.com/wailsapp/wails/v2/pkg/options"
	"github.com/wailsapp/wails/v2/pkg/options/assetserver"
	"github.com/wailsapp/wails/v2/pkg/options/linux"
	"github.com/wailsapp/wails/v2/pkg/options/windows"
)

//go:embed all:frontend/dist
var assets embed.FS

//go:embed build/appicon.png
var icon []byte

func main() {
	setupLogFile()
	app := NewApp()
	err := wails.Run(&options.App{
		Title:            "Messages",
		Width:            1040,
		Height:           720,
		MinWidth:         640,
		MinHeight:        420,
		AssetServer:      &assetserver.Options{Assets: assets, Handler: app.mediaSrv.handler(app)},
		BackgroundColour: &options.RGBA{R: 255, G: 255, B: 255, A: 0},
		OnStartup:        app.startup,
		OnShutdown:       app.shutdown,
		// Closing the window hides it (keeps notifications coming) when "keep running" is on. Quit (Ctrl+Q,
		// SIGTERM, logout) always exits: an OnBeforeClose hook would also intercept those.
		HideWindowOnClose: app.GetPrefs().KeepRunning,
		Bind:              []interface{}{app},
		SingleInstanceLock: &options.SingleInstanceLock{
			UniqueId:               "io.github.goobmessages.desktop",
			OnSecondInstanceLaunch: func(options.SecondInstanceData) { app.secondInstance() },
		},
		DragAndDrop: &options.DragAndDrop{EnableFileDrop: true, DisableWebViewDrop: true},
		Windows: &windows.Options{
			WebviewIsTransparent: false,
			WindowIsTranslucent:  false,
			BackdropType:         windows.Mica,
			Theme:                windows.SystemDefault,
		},
		Linux: &linux.Options{
			Icon:             icon,
			ProgramName:      "goobmessages",
			WebviewGpuPolicy: linux.WebviewGpuPolicyOnDemand,
		},
	})
	if err != nil {
		log.Fatal(err)
	}
}

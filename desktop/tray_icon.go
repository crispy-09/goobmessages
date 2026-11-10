package main

import (
	"bytes"
	"image"
	"image/color"
	"image/draw"
	"image/png"
	"sync"
)

// Tray icons are drawn from the embedded app icon (build/appicon.png): box-filtered down to the tray size, with a
// red dot in the corner while there are unread messages.

var (
	trayBaseOnce sync.Once
	trayBase     *image.RGBA
)

func trayBaseImage() *image.RGBA {
	trayBaseOnce.Do(func() {
		img, err := png.Decode(bytes.NewReader(icon))
		if err != nil {
			trayBase = image.NewRGBA(image.Rect(0, 0, 1, 1))
			return
		}
		b := img.Bounds()
		trayBase = image.NewRGBA(image.Rect(0, 0, b.Dx(), b.Dy()))
		draw.Draw(trayBase, trayBase.Bounds(), img, b.Min, draw.Src)
	})
	return trayBase
}

// trayIcon renders the icon at size×size (non-premultiplied RGBA).
func trayIcon(size int, badge bool) *image.NRGBA {
	src := trayBaseImage()
	sw, sh := src.Bounds().Dx(), src.Bounds().Dy()
	out := image.NewNRGBA(image.Rect(0, 0, size, size))
	for y := 0; y < size; y++ {
		y0, y1 := y*sh/size, max((y+1)*sh/size, y*sh/size+1)
		for x := 0; x < size; x++ {
			x0, x1 := x*sw/size, max((x+1)*sw/size, x*sw/size+1)
			var r, g, b, a, n uint64
			for yy := y0; yy < y1; yy++ {
				for xx := x0; xx < x1; xx++ {
					c := src.RGBAAt(xx, yy) // premultiplied
					r, g, b, a = r+uint64(c.R), g+uint64(c.G), b+uint64(c.B), a+uint64(c.A)
					n++
				}
			}
			if a == 0 {
				continue
			}
			// average premultiplied, then un-premultiply
			out.SetNRGBA(x, y, color.NRGBA{R: uint8(r * 255 / a), G: uint8(g * 255 / a), B: uint8(b * 255 / a), A: uint8(a / n)})
		}
	}
	if badge {
		red := color.NRGBA{R: 0xff, G: 0x3b, B: 0x30, A: 0xff}
		white := color.NRGBA{R: 0xff, G: 0xff, B: 0xff, A: 0xff}
		rad := float64(size) * 0.23
		cx, cy := float64(size)-rad-0.5, rad+0.5
		for y := 0; y < size; y++ {
			for x := 0; x < size; x++ {
				dx, dy := float64(x)+0.5-cx, float64(y)+0.5-cy
				d := dx*dx + dy*dy
				switch {
				case d <= rad*rad:
					out.SetNRGBA(x, y, red)
				case d <= (rad+1.2)*(rad+1.2): // thin white ring so the dot reads on any background
					out.SetNRGBA(x, y, white)
				}
			}
		}
	}
	return out
}

// trayIconPNG encodes trayIcon as PNG.
func trayIconPNG(size int, badge bool) []byte {
	var buf bytes.Buffer
	_ = png.Encode(&buf, trayIcon(size, badge))
	return buf.Bytes()
}

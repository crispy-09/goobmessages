//go:build linux && cgo && webkit2_41

package main

// #cgo pkg-config: gtk+-3.0 webkit2gtk-4.1
import "C"

//go:build !windows && !(linux && cgo)

package main

import "context"

// The macOS client lives in the repository root; this module targets Linux and Windows.
func googleSignIn(context.Context) (map[string]string, error) { return nil, errSignInFailed }

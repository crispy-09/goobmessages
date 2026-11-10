//go:build linux && cgo

package main

/*
#include <stdlib.h>
#include "signin_linux.h"
*/
import "C"

import (
	"context"
	"sync"
	"unsafe"
)

type signInResult struct {
	cookies string
	ok      bool
}

var (
	signInMu      sync.Mutex
	signInPending = map[uintptr]chan signInResult{}
	signInNext    uintptr
)

//export goSignInResult
func goSignInResult(handle C.uintptr_t, cookies *C.char, ok C.int) {
	signInMu.Lock()
	ch := signInPending[uintptr(handle)]
	delete(signInPending, uintptr(handle))
	signInMu.Unlock()
	if ch != nil {
		ch <- signInResult{C.GoString(cookies), ok != 0}
	}
}

//export goSignInLog
func goSignInLog(msg *C.char) { signInLogf("%s", C.GoString(msg)) }

// googleSignIn shows Google's sign-in page and returns the account cookies.
func googleSignIn(ctx context.Context) (map[string]string, error) {
	signInMu.Lock()
	if len(signInPending) > 0 {
		signInMu.Unlock()
		return nil, errSignInFailed
	}
	signInNext++
	handle := signInNext
	ch := make(chan signInResult, 1)
	signInPending[handle] = ch
	signInMu.Unlock()

	cs := []*C.char{C.CString(signInURL), C.CString(cookieURI), C.CString(safariUA), C.CString(signInTitle)}
	defer func() {
		for _, c := range cs {
			C.free(unsafe.Pointer(c))
		}
	}()
	C.goob_signin_start(C.uintptr_t(handle), cs[0], cs[1], cs[2], cs[3]) // copies the strings

	var r signInResult
	select {
	case r = <-ch:
	case <-ctx.Done():
		C.goob_signin_close(C.uintptr_t(handle))
		r = <-ch
	}
	if !r.ok {
		return nil, errSignInCancelled
	}
	cookies, ok := parseCookieLines(r.cookies)
	if !ok {
		return nil, errSignInFailed
	}
	return cookies, nil
}

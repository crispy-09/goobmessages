package main

import (
	"encoding/base64"
	"errors"

	"github.com/goobmessages/desktop/internal/msgcache"
	"github.com/zalando/go-keyring"
)

// The message cache key lives in the OS keyring (Secret Service "login" collection on Linux, Credential Manager on
// Windows), not next to the cache. Without it the cache stays off; unpairing deletes it, so leftover cache files
// (or copies of them, e.g. on an SSD or in a backup) can't be decrypted.
const (
	keyringService = "GoobMessages"
	keyringUser    = "message-cache-key"
)

// unlockMessageCache loads or creates the key and turns the cache on. Run it in a goroutine: if the keyring is locked
// the desktop shows its unlock prompt, and this waits for it. Until then chats simply load from the phone.
func (a *App) unlockMessageCache() {
	gen := a.msgCache.Generation()
	stored, err := keyring.Get(keyringService, keyringUser)
	if err == nil {
		if key, derr := base64.StdEncoding.DecodeString(stored); derr == nil && len(key) == msgcache.KeySize {
			a.setCacheKey(gen, key, false)
			return
		}
		a.log.Warn().Msg("Message cache key in the keyring is invalid, replacing it")
	} else if !errors.Is(err, keyring.ErrNotFound) {
		a.log.Warn().Err(err).Msg("Keyring unavailable, message cache is off")
		return
	}
	key := msgcache.NewKey()
	if err := keyring.Set(keyringService, keyringUser, base64.StdEncoding.EncodeToString(key)); err != nil {
		a.log.Warn().Err(err).Msg("Couldn't save the message cache key to the keyring, message cache is off")
		return
	}
	a.setCacheKey(gen, key, true)
}

func (a *App) setCacheKey(gen uint64, key []byte, fresh bool) {
	// An unpair while the keyring prompt was open: that key is being deleted, don't use it.
	if a.msgCache.Generation() != gen {
		return
	}
	if err := a.msgCache.SetKey(key, fresh); err != nil {
		a.log.Warn().Err(err).Msg("Message cache key rejected")
		return
	}
	a.log.Info().Bool("new_key", fresh).Msg("Message cache unlocked")
}

// resetMessageCache deletes the cache and its key (unpairing), then sets up a new key for the next pairing.
func (a *App) resetMessageCache() {
	a.stopCacheSaves()
	a.msgCache.Clear()
	go func() {
		if err := keyring.Delete(keyringService, keyringUser); err != nil && !errors.Is(err, keyring.ErrNotFound) {
			a.log.Warn().Err(err).Msg("Couldn't delete the message cache key")
		}
		a.unlockMessageCache()
	}()
}

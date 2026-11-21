package main

import (
	"os"
	"path/filepath"
	"time"

	"github.com/goobmessages/desktop/internal/model"
)

// The on-disk message cache (internal/msgcache): opened conversations are saved a few seconds after they change,
// restored instantly when opened again (also after a restart), then synced with the phone's newest page.

func messageCacheDir() string {
	base, err := os.UserCacheDir()
	if err != nil {
		base = os.TempDir()
	}
	return filepath.Join(base, "GoobMessages", "messages")
}

// restoreFromCache shows a cached conversation and refreshes it from the phone in the background.
func (a *App) restoreFromCache(cid string) bool {
	msgs, cur, ok := a.msgCache.Load(cid)
	if !ok {
		return false
	}
	a.store.AddHistory(cid, msgs)
	if a.store.Cursor(cid) == (model.Cursor{}) {
		a.store.SetCursor(cid, cur)
	}
	go a.syncCached(cid)
	return true
}

// syncCached fetches the newest page and merges it into a conversation restored from the cache. If the page doesn't
// reach back to the cached messages (more arrived while the app was closed than fit in a page), the cache can't be
// joined up with it and the conversation starts over from that page.
func (a *App) syncCached(cid string) {
	cachedNewest := a.store.NewestTimestamp(cid)
	msgs, next, err := a.fetchPage(cid, nil)
	if err != nil {
		a.log.Warn().Err(err).Str("conversation", cid).Msg("Refreshing cached messages failed")
		return
	}
	if len(msgs) == 0 {
		return
	}
	oldest := msgs[0].Timestamp
	for _, m := range msgs {
		oldest = min(oldest, m.Timestamp)
	}
	done := next.GetLastItemID() == ""
	if !done && oldest > cachedNewest {
		a.store.ReplaceHistory(cid, msgs)
		a.store.SetCursor(cid, model.Cursor{LastItemID: next.GetLastItemID(), LastItemTimestamp: next.GetLastItemTimestamp()})
	} else {
		a.store.SyncNewest(cid, msgs, done)
		if done {
			a.store.SetCursor(cid, model.Cursor{Done: true})
		}
	}
	a.emitMessages(cid)
}

func (a *App) scheduleCacheSave(cid string) {
	a.cacheMu.Lock()
	defer a.cacheMu.Unlock()
	if a.quit.Load() || a.cacheSave[cid] != nil {
		return
	}
	a.cacheSave[cid] = time.AfterFunc(cacheSaveDelay, func() {
		a.cacheMu.Lock()
		delete(a.cacheSave, cid)
		a.cacheMu.Unlock()
		a.saveCached(cid)
	})
}

func (a *App) saveCached(cid string) {
	gen := a.msgCache.Generation() // read first: a Clear (unpair) after this point makes the save a no-op
	if !a.store.IsTracked(cid) {
		return
	}
	if err := a.msgCache.Save(gen, cid, a.store.Messages(cid), a.store.Cursor(cid)); err != nil {
		a.log.Warn().Err(err).Msg("Saving message cache failed")
	}
}

// flushCacheSaves writes pending saves now (quitting).
func (a *App) flushCacheSaves() {
	a.cacheMu.Lock()
	var pending []string
	for cid, t := range a.cacheSave {
		if t.Stop() {
			pending = append(pending, cid)
		}
		delete(a.cacheSave, cid)
	}
	a.cacheMu.Unlock()
	for _, cid := range pending {
		a.saveCached(cid)
	}
}

// stopCacheSaves drops pending saves (unpairing: the cache is about to be cleared).
func (a *App) stopCacheSaves() {
	a.cacheMu.Lock()
	for cid, t := range a.cacheSave {
		t.Stop()
		delete(a.cacheSave, cid)
	}
	a.cacheMu.Unlock()
}

func (a *App) forgetCached(cid string) {
	a.cacheMu.Lock()
	if t := a.cacheSave[cid]; t != nil {
		t.Stop()
		delete(a.cacheSave, cid)
	}
	a.cacheMu.Unlock()
	a.msgCache.Delete(cid)
}

// upsertConversation stores a conversation from the phone; one deleted, blocked or marked as spam there is also
// removed from the disk cache.
func (a *App) upsertConversation(c model.Conversation) {
	a.store.UpsertConversation(c)
	if c.Hidden {
		a.forgetCached(c.ID)
	}
}

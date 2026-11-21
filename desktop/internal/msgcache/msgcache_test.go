package msgcache

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/goobmessages/desktop/internal/model"
)

func newKeyed(t *testing.T, dir string, perConv int, maxBytes int64) *Cache {
	t.Helper()
	c := New(dir, perConv, maxBytes)
	if err := c.SetKey(NewKey(), false); err != nil {
		t.Fatal(err)
	}
	return c
}

func msgs(cid string, n int) []model.Message {
	out := make([]model.Message, n)
	for i := range out {
		out[i] = model.Message{ID: fmt.Sprint(i + 1), ConversationID: cid, Text: strings.Repeat("x", 200) + fmt.Sprint(i), Timestamp: int64(1000 + i)}
	}
	return out
}

func TestRoundTripKeepsInlineAndSkipsLocal(t *testing.T) {
	c := newKeyed(t, t.TempDir(), 100, 1<<20)
	list := msgs("c1", 3)
	list[1].Media = []model.Media{{ID: "inline:c1:2:0", Inline: []byte("png")}, {ID: "big", Inline: make([]byte, MaxInlineBytes+1)}}
	list = append(list, model.Message{TmpID: "t", ConversationID: "c1", Local: true, Timestamp: 5000})
	cur := model.Cursor{LastItemID: "x", LastItemTimestamp: 7}
	if err := c.Save(c.Generation(), "c1", list, cur); err != nil {
		t.Fatal(err)
	}
	got, gotCur, ok := c.Load("c1")
	if !ok || len(got) != 3 || gotCur != cur {
		t.Fatalf("load: ok=%v n=%d cur=%+v", ok, len(got), gotCur)
	}
	if string(got[1].Media[0].Inline) != "png" || got[1].Media[1].Inline != nil {
		t.Fatalf("inline media not restored as expected: %+v", got[1].Media)
	}
	if _, _, ok := c.Load("other"); ok {
		t.Fatal("unknown conversation loaded")
	}
}

func TestTruncatesToNewestAndPointsCursorBeforeThem(t *testing.T) {
	c := newKeyed(t, t.TempDir(), 10, 1<<20)
	if err := c.Save(c.Generation(), "c1", msgs("c1", 25), model.Cursor{Done: true}); err != nil {
		t.Fatal(err)
	}
	got, cur, _ := c.Load("c1")
	if len(got) != 10 || got[0].ID != "16" || got[9].ID != "25" {
		t.Fatalf("kept %d messages starting at %s", len(got), got[0].ID)
	}
	if cur.Done || cur.LastItemID != "16" || cur.LastItemTimestamp != got[0].Timestamp {
		t.Fatalf("cursor %+v should continue before the oldest kept message", cur)
	}
}

func TestEvictsLeastRecentlyUsed(t *testing.T) {
	dir := t.TempDir()
	c := newKeyed(t, dir, 1000, 1<<40)
	for _, cid := range []string{"a", "b", "c"} {
		if err := c.Save(c.Generation(), cid, msgs(cid, 300), model.Cursor{}); err != nil {
			t.Fatal(err)
		}
	}
	// Make "a" the oldest-used and "b" recently used, then shrink the cap to fit roughly two files.
	old := time.Now().Add(-time.Hour)
	_ = os.Chtimes(c.path("a"), old, old)
	_ = os.Chtimes(c.path("c"), old.Add(time.Minute), old.Add(time.Minute))
	c.Load("b")
	st, _ := os.Stat(c.path("b"))
	c.maxBytes = 2*st.Size() + st.Size()/2
	if err := c.Save(c.Generation(), "d", msgs("d", 300), model.Cursor{}); err != nil {
		t.Fatal(err)
	}
	for cid, want := range map[string]bool{"a": false, "c": false, "b": true, "d": true} {
		if _, _, ok := c.Load(cid); ok != want {
			t.Errorf("%s cached=%v, want %v", cid, ok, want)
		}
	}
	if m, _ := filepath.Glob(filepath.Join(dir, ".tmp-*")); len(m) > 0 {
		t.Errorf("temp files left: %v", m)
	}
}

func TestClearAndDelete(t *testing.T) {
	c := newKeyed(t, filepath.Join(t.TempDir(), "m"), 100, 1<<20)
	_ = c.Save(c.Generation(), "a", msgs("a", 2), model.Cursor{})
	_ = c.Save(c.Generation(), "b", msgs("b", 2), model.Cursor{})
	c.Delete("a")
	if _, _, ok := c.Load("a"); ok {
		t.Fatal("deleted conversation still cached")
	}
	c.Clear()
	if _, _, ok := c.Load("b"); ok {
		t.Fatal("cleared cache still has b")
	}
	_ = c.SetKey(NewKey(), true)
	if err := c.Save(c.Generation(), "a", msgs("a", 1), model.Cursor{}); err != nil {
		t.Fatal("save after clear:", err)
	}
	if _, _, ok := c.Load("a"); !ok {
		t.Fatal("cache not usable after a new key")
	}
}

func TestSaveFromBeforeClearIsDropped(t *testing.T) {
	c := newKeyed(t, t.TempDir(), 100, 1<<20)
	gen := c.Generation()
	c.Clear() // unpaired while a save was in flight
	if err := c.Save(gen, "a", msgs("a", 2), model.Cursor{}); err != nil {
		t.Fatal(err)
	}
	if _, _, ok := c.Load("a"); ok {
		t.Fatal("stale save wrote data after Clear")
	}
}

func TestStaleTempFilesAreRemoved(t *testing.T) {
	dir := t.TempDir()
	c := newKeyed(t, dir, 100, 1<<20)
	stale := filepath.Join(dir, ".tmp-crashed")
	_ = os.WriteFile(stale, []byte("x"), 0o600)
	old := time.Now().Add(-time.Hour)
	_ = os.Chtimes(stale, old, old)
	if err := c.Save(c.Generation(), "a", msgs("a", 1), model.Cursor{}); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(stale); !os.IsNotExist(err) {
		t.Fatal("stale temp file not removed")
	}
}

func TestNoKeyMeansNoCache(t *testing.T) {
	dir := t.TempDir()
	c := New(dir, 100, 1<<20)
	if err := c.Save(c.Generation(), "a", msgs("a", 2), model.Cursor{}); err != nil {
		t.Fatal(err)
	}
	if ents, _ := os.ReadDir(dir); len(ents) != 0 {
		t.Fatalf("wrote %d files without a key", len(ents))
	}
	if _, _, ok := c.Load("a"); ok {
		t.Fatal("loaded without a key")
	}
}

func TestEncryptedAtRest(t *testing.T) {
	dir := t.TempDir()
	c := newKeyed(t, dir, 100, 1<<20)
	list := msgs("a", 2)
	list[0].Text = "secret-marker-text"
	_ = c.Save(c.Generation(), "a", list, model.Cursor{})
	raw, err := os.ReadFile(c.path("a"))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(string(raw), magic) || strings.Contains(string(raw), "secret-marker") {
		t.Fatal("file is not encrypted")
	}
	// Another key (e.g. after the keyring entry was lost) can't read it, and the useless file is removed.
	other := New(dir, 100, 1<<20)
	_ = other.SetKey(NewKey(), false)
	if _, _, ok := other.Load("a"); ok {
		t.Fatal("read with the wrong key")
	}
	if _, err := os.Stat(c.path("a")); !os.IsNotExist(err) {
		t.Fatal("undecryptable file kept")
	}
}

func TestFilesCannotBeSwappedBetweenChats(t *testing.T) {
	c := newKeyed(t, t.TempDir(), 100, 1<<20)
	_ = c.Save(c.Generation(), "a", msgs("a", 2), model.Cursor{})
	_ = c.Save(c.Generation(), "b", msgs("b", 2), model.Cursor{})
	if err := os.Rename(c.path("a"), c.path("b")); err != nil {
		t.Fatal(err)
	}
	if _, _, ok := c.Load("b"); ok {
		t.Fatal("a's file was accepted as b's")
	}
}

func TestFreshKeyDeletesOldFiles(t *testing.T) {
	dir := t.TempDir()
	_ = os.WriteFile(filepath.Join(dir, "old.json.gz"), []byte("plaintext from an older version"), 0o600)
	c := New(dir, 100, 1<<20)
	_ = c.SetKey(NewKey(), true)
	if ents, _ := os.ReadDir(dir); len(ents) != 0 {
		t.Fatal("old files kept after a fresh key")
	}
}

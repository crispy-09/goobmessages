// Package msgcache keeps recently viewed conversations on disk so reopening a chat (even after a restart) shows its
// history immediately instead of waiting for the phone. One file per conversation (gzipped JSON, encrypted with
// AES-256-GCM under a key the app keeps in the OS keyring), readable only by the user, capped per conversation and in
// total (least recently used conversations are evicted first). Without a key the cache is off: nothing is read or
// written.
package msgcache

import (
	"bytes"
	"compress/gzip"
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/goobmessages/desktop/internal/model"
)

const (
	version = 2
	magic   = "GMC2" // file header: magic, 12-byte nonce, then AES-GCM ciphertext of the gzipped JSON
	// KeySize is the cache key length (AES-256).
	KeySize = 32
	// MaxInlineBytes: attachment bytes that came inside a message are kept up to this size; bigger ones are left
	// out (the attachment shows as unavailable until the message is fetched from the phone again).
	MaxInlineBytes = 512 << 10
)

type entry struct {
	Version  int               `json:"v"`
	Cursor   model.Cursor      `json:"cursor"`
	Messages []model.Message   `json:"messages"`
	Inline   map[string][]byte `json:"inline,omitempty"` // media id -> bytes (Media.Inline isn't serialized)
}

type Cache struct {
	mu         sync.Mutex
	gen        uint64 // bumped by Clear; saves from an older generation are dropped
	aead       cipher.AEAD
	dir        string
	maxPerConv int
	maxBytes   int64
}

// New returns a cache in dir keeping at most maxPerConv messages per conversation and maxBytes on disk overall.
func New(dir string, maxPerConv int, maxBytes int64) *Cache {
	return &Cache{dir: dir, maxPerConv: maxPerConv, maxBytes: maxBytes}
}

// SetKey turns the cache on with a KeySize-byte key. fresh means the key was just created: files encrypted under an
// earlier key (or from an older, unencrypted version) can never be read again and are deleted.
func (c *Cache) SetKey(key []byte, fresh bool) error {
	block, err := aes.NewCipher(key)
	if err != nil {
		return err
	}
	if len(key) != KeySize {
		return errors.New("msgcache: key must be 32 bytes")
	}
	aead, err := cipher.NewGCM(block)
	if err != nil {
		return err
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if fresh {
		_ = os.RemoveAll(c.dir)
	}
	c.aead = aead
	return nil
}

// NewKey returns a random cache key.
func NewKey() []byte {
	k := make([]byte, KeySize)
	if _, err := rand.Read(k); err != nil {
		panic(err) // crypto/rand doesn't fail on supported platforms
	}
	return k
}

func (c *Cache) path(cid string) string {
	h := sha256.Sum256([]byte(cid))
	return filepath.Join(c.dir, hex.EncodeToString(h[:16])+".json.gz")
}

// Load returns the cached messages (oldest first) and the cursor to continue loading older ones from.
func (c *Cache) Load(cid string) ([]model.Message, model.Cursor, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.aead == nil {
		return nil, model.Cursor{}, false
	}
	p := c.path(cid)
	sealed, err := os.ReadFile(p)
	if err != nil {
		return nil, model.Cursor{}, false
	}
	plain, err := c.open(filepath.Base(p), sealed)
	if err != nil {
		_ = os.Remove(p) // wrong key, old format or damaged: it can't be used
		return nil, model.Cursor{}, false
	}
	zr, err := gzip.NewReader(bytes.NewReader(plain))
	if err != nil {
		return nil, model.Cursor{}, false
	}
	var e entry
	if err := json.NewDecoder(io.LimitReader(zr, 4*c.maxBytes+(1<<20))).Decode(&e); err != nil || e.Version != version || len(e.Messages) == 0 {
		return nil, model.Cursor{}, false
	}
	for i := range e.Messages {
		m := &e.Messages[i]
		if m.ConversationID != cid {
			return nil, model.Cursor{}, false
		}
		for j := range m.Media {
			m.Media[j].Inline = e.Inline[m.Media[j].ID]
		}
	}
	now := time.Now()
	_ = os.Chtimes(p, now, now) // mtime = last use, for eviction
	return e.Messages, e.Cursor, true
}

// Generation identifies the cache's contents; pass it to Save. Read it before snapshotting the messages.
func (c *Cache) Generation() uint64 {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.gen
}

// Save stores a conversation's messages (oldest first) and its older-history cursor. Optimistic local messages are
// skipped; if the list is longer than the cap only the newest are kept and the cursor points before them. Nothing is
// written if the cache was cleared since gen was read, so an in-flight save can't bring back data after unpairing.
func (c *Cache) Save(gen uint64, cid string, msgs []model.Message, cur model.Cursor) error {
	keep := make([]model.Message, 0, len(msgs))
	for _, m := range msgs {
		if !m.Local && m.ID != "" {
			keep = append(keep, m)
		}
	}
	if len(keep) == 0 {
		return nil
	}
	if len(keep) > c.maxPerConv {
		keep = keep[len(keep)-c.maxPerConv:]
		cur = model.Cursor{LastItemID: keep[0].ID, LastItemTimestamp: keep[0].Timestamp}
	}
	e := entry{Version: version, Cursor: cur, Messages: keep}
	for _, m := range keep {
		for _, md := range m.Media {
			if n := len(md.Inline); n > 0 && n <= MaxInlineBytes {
				if e.Inline == nil {
					e.Inline = map[string][]byte{}
				}
				e.Inline[md.ID] = md.Inline
			}
		}
	}

	c.mu.Lock()
	defer c.mu.Unlock()
	if gen != c.gen || c.aead == nil {
		return nil
	}
	var buf bytes.Buffer
	zw := gzip.NewWriter(&buf)
	if err := json.NewEncoder(zw).Encode(&e); err != nil {
		return err
	}
	if err := zw.Close(); err != nil {
		return err
	}
	p := c.path(cid)
	sealed := c.seal(filepath.Base(p), buf.Bytes())
	if err := os.MkdirAll(c.dir, 0o700); err != nil {
		return err
	}
	f, err := os.CreateTemp(c.dir, ".tmp-*")
	if err != nil {
		return err
	}
	tmp := f.Name()
	defer os.Remove(tmp)
	_, err = f.Write(sealed)
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	if err != nil {
		return err
	}
	if err := os.Rename(tmp, p); err != nil {
		return err
	}
	c.evictLocked(p)
	return nil
}

// evictLocked deletes least recently used conversations until the cache fits; the file just written is kept.
func (c *Cache) evictLocked(keep string) {
	ents, err := os.ReadDir(c.dir)
	if err != nil {
		return
	}
	type file struct {
		path string
		size int64
		mod  time.Time
	}
	var files []file
	var total int64
	for _, de := range ents {
		info, err := de.Info()
		if err != nil || de.IsDir() {
			continue
		}
		// Temp files are renamed or removed right away; one left behind by a crash is stale after a minute.
		if strings.HasPrefix(de.Name(), ".tmp-") {
			if time.Since(info.ModTime()) > time.Minute {
				_ = os.Remove(filepath.Join(c.dir, de.Name()))
			}
			continue
		}
		if !strings.HasSuffix(de.Name(), ".json.gz") {
			continue
		}
		files = append(files, file{filepath.Join(c.dir, de.Name()), info.Size(), info.ModTime()})
		total += info.Size()
	}
	sort.Slice(files, func(i, j int) bool { return files[i].mod.Before(files[j].mod) })
	for _, f := range files {
		if total <= c.maxBytes {
			break
		}
		if f.path == keep {
			continue
		}
		if err := os.Remove(f.path); err == nil || errors.Is(err, os.ErrNotExist) {
			total -= f.size
		}
	}
}

// Delete forgets one conversation.
func (c *Cache) Delete(cid string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	_ = os.Remove(c.path(cid))
}

// seal encrypts plain for the file named name (the name is authenticated, so files can't be swapped between chats).
func (c *Cache) seal(name string, plain []byte) []byte {
	nonce := make([]byte, c.aead.NonceSize())
	if _, err := rand.Read(nonce); err != nil {
		panic(err)
	}
	out := append([]byte(magic), nonce...)
	return c.aead.Seal(out, nonce, plain, []byte(name))
}

func (c *Cache) open(name string, sealed []byte) ([]byte, error) {
	n := len(magic) + c.aead.NonceSize()
	if len(sealed) < n || string(sealed[:len(magic)]) != magic {
		return nil, errors.New("msgcache: not an encrypted cache file")
	}
	return c.aead.Open(nil, sealed[len(magic):n], sealed[n:], []byte(name))
}

// Clear deletes everything and forgets the key (unpairing); SetKey turns the cache back on.
func (c *Cache) Clear() {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.gen++
	c.aead = nil
	_ = os.RemoveAll(c.dir)
}

// Package storage persists the paired session and user preferences in the per-user config directory
// (~/.config/GoobMessages on Linux, %AppData%\GoobMessages on Windows). Files are written atomically with
// owner-only permissions. Message content is never written to disk.
package storage

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"sync"

	"github.com/google/uuid"
	"go.mau.fi/mautrix-gmessages/pkg/libgm"
)

const appDir = "GoobMessages"

func dir() (string, error) {
	base, err := os.UserConfigDir()
	if err != nil {
		return "", err
	}
	d := filepath.Join(base, appDir)
	return d, os.MkdirAll(d, 0o700)
}

func writeAtomic(name string, data []byte) error {
	d, err := dir()
	if err != nil {
		return err
	}
	f, err := os.CreateTemp(d, "."+name+".*")
	if err != nil {
		return err
	}
	tmp := f.Name()
	defer os.Remove(tmp)
	// CreateTemp creates the file 0600 on Unix; on Windows the per-user AppData ACL protects it.
	if _, err := f.Write(data); err != nil {
		f.Close()
		return err
	}
	if err := f.Sync(); err != nil {
		f.Close()
		return err
	}
	if err := f.Close(); err != nil {
		return err
	}
	return os.Rename(tmp, filepath.Join(d, name))
}

func read(name string) ([]byte, error) {
	d, err := dir()
	if err != nil {
		return nil, err
	}
	return os.ReadFile(filepath.Join(d, name))
}

// Session is everything needed to resume without re-pairing.
type Session struct {
	Auth *libgm.AuthData `json:"auth"`
}

var sessionMu sync.Mutex

func LoadSession() (*libgm.AuthData, error) {
	sessionMu.Lock()
	defer sessionMu.Unlock()
	b, err := read("session.json")
	if err != nil {
		return nil, err
	}
	var s Session
	if err := json.Unmarshal(b, &s); err != nil {
		return nil, err
	}
	if s.Auth == nil || s.Auth.Mobile == nil || s.Auth.Browser == nil {
		return nil, errors.New("session is not paired")
	}
	if s.Auth.IsGoogleAccount() && (!s.Auth.HasCookies() || s.Auth.PairingID == uuid.Nil) {
		return nil, errors.New("google session is incomplete")
	}
	return s.Auth, nil
}

func SaveSession(a *libgm.AuthData) error {
	sessionMu.Lock()
	defer sessionMu.Unlock()
	b, err := json.Marshal(Session{Auth: a})
	if err != nil {
		return err
	}
	return writeAtomic("session.json", b)
}

func DeleteSession() error {
	sessionMu.Lock()
	defer sessionMu.Unlock()
	d, err := dir()
	if err != nil {
		return err
	}
	err = os.Remove(filepath.Join(d, "session.json"))
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	return err
}

// Prefs are user settings shown in the Settings sheet.
type Prefs struct {
	Notifications bool            `json:"notifications"`
	Previews      bool            `json:"previews"`
	KeepRunning   bool            `json:"keepRunning"` // closing the window hides it
	EnterToSend   bool            `json:"enterToSend"`
	HiddenAlerts  map[string]bool `json:"hiddenAlerts"`
	// LinkPreviews: "everyone", "contacts" (links from saved contacts and from you) or "off".
	LinkPreviews string `json:"linkPreviews"`
}

func DefaultPrefs() Prefs {
	return Prefs{Notifications: true, Previews: true, KeepRunning: true, EnterToSend: true,
		HiddenAlerts: map[string]bool{}, LinkPreviews: "contacts"}
}

func LoadPrefs() Prefs {
	p := DefaultPrefs()
	if b, err := read("prefs.json"); err == nil {
		_ = json.Unmarshal(b, &p)
	}
	if p.HiddenAlerts == nil {
		p.HiddenAlerts = map[string]bool{}
	}
	switch p.LinkPreviews {
	case "everyone", "contacts", "off":
	default:
		p.LinkPreviews = "contacts"
	}
	return p
}

func SavePrefs(p Prefs) error {
	b, err := json.MarshalIndent(p, "", "  ")
	if err != nil {
		return err
	}
	return writeAtomic("prefs.json", b)
}

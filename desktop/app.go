package main

import (
	"context"
	"encoding/base64"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	goruntime "runtime"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/rs/zerolog"
	"github.com/wailsapp/wails/v2/pkg/runtime"
	"go.mau.fi/mautrix-gmessages/pkg/libgm"
	"go.mau.fi/mautrix-gmessages/pkg/libgm/events"
	"go.mau.fi/mautrix-gmessages/pkg/libgm/gmproto"
	"go.mau.fi/mautrix-gmessages/pkg/libgm/util"
	"go.mau.fi/util/exhttp"

	"github.com/goobmessages/desktop/internal/model"
	"github.com/goobmessages/desktop/internal/storage"
	"github.com/goobmessages/desktop/internal/urlsafe"
)

// Phases shown by the frontend.
const (
	PhaseLoading    = "loading"
	PhaseLogin      = "login"
	PhaseConnecting = "connecting"
	PhaseReady      = "ready"
)

const (
	maxAttachmentBytes = 100 << 20 // Google Messages rejects larger uploads anyway
	maxDownloadBytes   = 150 << 20
	mediaCacheBytes    = 256 << 20
	pageSize           = 40
)

type Status struct {
	Phase  string `json:"phase"`
	Banner string `json:"banner"`
	Error  string `json:"error"`
	Unread int    `json:"unread"`
	// Inactive is true when Messages for web is open elsewhere and this client is not the active session.
	Inactive bool `json:"inactive"`
}

// App is bound to the frontend: its exported methods are callable from JavaScript.
type App struct {
	ctx   context.Context
	log   zerolog.Logger
	store *model.Store
	notif *Notifier

	mu       sync.Mutex
	cli      *libgm.Client
	status   Status
	sims     []*gmproto.SIMCard
	prefs    storage.Prefs
	pairStop context.CancelFunc
	runCtx   context.Context // cancelled on logout / client replacement
	runStop  context.CancelFunc

	reconnecting   atomic.Bool
	reconnectTimer *time.Timer
	asleep         atomic.Bool

	convEmit      *time.Timer
	fetchingConv  map[string]bool
	lastListFetch time.Time
	markReadTimer map[string]*time.Timer
	typingSentAt  map[string]time.Time
	loading       map[string]chan struct{} // in-flight history loads per conversation

	mediaCache *byteLRU
	mediaSrv   *mediaServer
	tray       trayHandle
	previews   *previewStore
	avatar     *avatarLoader
	quit       atomic.Bool
}

func NewApp() *App {
	a := &App{
		store:         model.NewStore(),
		prefs:         storage.LoadPrefs(),
		fetchingConv:  map[string]bool{},
		markReadTimer: map[string]*time.Timer{},
		typingSentAt:  map[string]time.Time{},
		mediaCache:    newByteLRU(mediaCacheBytes),
		mediaSrv:      newMediaServer(),
		previews:      newPreviewStore(),
		status:        Status{Phase: PhaseLoading},
	}
	a.notif = NewNotifier(func() (bool, bool, map[string]bool) {
		a.mu.Lock()
		defer a.mu.Unlock()
		h := make(map[string]bool, len(a.prefs.HiddenAlerts))
		for k, v := range a.prefs.HiddenAlerts {
			h[k] = v
		}
		return a.prefs.Notifications, a.prefs.Previews, h
	})
	a.avatar = newAvatarLoader(a)
	return a
}

// ---------------------------------------------------------------- lifecycle

func (a *App) startup(ctx context.Context) {
	a.ctx = ctx
	a.log = zerolog.New(zerolog.ConsoleWriter{Out: logOut, TimeFormat: time.Kitchen, NoColor: true}).Level(zerolog.InfoLevel).With().Timestamp().Logger()
	a.log.Info().Str("version", appVersion).Msg("Starting Goob Messages")
	a.notif.Start(ctx)
	runtime.OnNotificationResponse(ctx, a.onNotificationResponse)
	a.tray = startTray(a)
	go a.watchSleep()

	auth, err := storage.LoadSession()
	if err != nil {
		a.setPhase(PhaseLogin, "")
		if autoSignIn {
			a.StartPairing()
		}
		return
	}
	a.notif.BeginCatchUp()
	go a.connect(auth)
}

func (a *App) shutdown(ctx context.Context) {
	a.quit.Store(true)
	a.mu.Lock()
	cli := a.cli
	a.mu.Unlock()
	if cli != nil {
		cli.Disconnect()
	}
	a.notif.Stop()
	if a.tray != nil {
		a.tray.Close()
	}
}

// Quit really exits (from the app menu).
func (a *App) Quit() {
	a.quit.Store(true)
	runtime.Quit(a.ctx)
}

func (a *App) secondInstance() {
	runtime.WindowUnminimise(a.ctx)
	runtime.WindowShow(a.ctx)
}

// watchSleep detects suspend/resume portably: a wall-clock jump much larger than the tick means the machine
// slept. On wake, hold notifications (the backlog arrives at once) and reconnect once.
func (a *App) watchSleep() {
	const tick = 10 * time.Second
	last := time.Now().Round(0) // strip monotonic reading so the gap reflects wall time
	for !a.quit.Load() {
		time.Sleep(tick)
		now := time.Now().Round(0)
		gap := now.Sub(last)
		last = now
		if gap > 4*tick {
			a.log.Info().Dur("gap", gap).Msg("Resumed from sleep")
			a.notif.BeginCatchUp()
			a.scheduleReconnect(2 * time.Second)
		}
	}
}

func (a *App) setPhase(phase, errMsg string) {
	a.mu.Lock()
	a.status.Phase = phase
	a.status.Error = errMsg
	if phase != PhaseReady {
		a.status.Banner = ""
	}
	a.mu.Unlock()
	a.emitStatus()
}

func (a *App) setBanner(b string) {
	a.mu.Lock()
	changed := a.status.Banner != b
	a.status.Banner = b
	a.mu.Unlock()
	if changed {
		a.emitStatus()
	}
}

func (a *App) emitStatus() {
	s := a.GetStatus()
	runtime.EventsEmit(a.ctx, "status", s)
	title := "Messages"
	if s.Unread > 0 {
		title = fmt.Sprintf("Messages (%d)", s.Unread)
	}
	runtime.WindowSetTitle(a.ctx, title)
	if a.tray != nil {
		a.tray.SetUnread(s.Unread)
	}
}

func (a *App) GetStatus() Status {
	a.mu.Lock()
	s := a.status
	a.mu.Unlock()
	s.Unread = a.store.UnreadCount()
	return s
}

func (a *App) newClient(auth *libgm.AuthData) *libgm.Client {
	cli := libgm.NewClient(auth, nil, a.log.With().Str("component", "libgm").Logger(), exhttp.SensibleClientSettings)
	return cli
}

// connect resumes a paired session. Called from a goroutine.
func (a *App) connect(auth *libgm.AuthData) {
	a.setPhase(PhaseConnecting, "")
	cli := a.newClient(auth)
	cli.SetEventHandler(a.handleEvent)
	runCtx, stop := context.WithCancel(context.Background())
	a.mu.Lock()
	if a.runStop != nil {
		a.runStop()
	}
	a.cli, a.runCtx, a.runStop = cli, runCtx, stop
	a.mu.Unlock()

	if err := cli.FetchConfig(runCtx); err != nil {
		a.log.Warn().Err(err).Msg("Failed to fetch config")
	} else if auth.IsGoogleAccount() && cli.Config.GetDeviceInfo().GetEmail() == "" {
		a.loggedOut("Google signed you out. Sign in again.")
		return
	}
	for attempt := 0; ; attempt++ {
		err := cli.Connect(runCtx)
		if err == nil {
			break
		}
		if runCtx.Err() != nil {
			return
		}
		if isAuthError(err) {
			a.loggedOut("Your session expired. Pair your phone again.")
			return
		}
		a.log.Warn().Err(err).Int("attempt", attempt).Msg("Connect failed")
		a.setBanner("Can't reach Google Messages. Retrying…")
		select {
		case <-time.After(backoff(attempt)):
		case <-runCtx.Done():
			return
		}
	}
	_ = storage.SaveSession(auth)
	a.setPhase(PhaseReady, "")
	a.notif.EndCatchUp(4 * time.Second)
	go a.refreshConversations(true)
}

// isAuthError mirrors libgm's isFatalRefreshError: the session is no longer valid and must be re-paired.
func isAuthError(err error) bool {
	if errors.Is(err, events.ErrInvalidCredentials) || errors.Is(err, events.ErrRequestedEntityNotFound) {
		return true
	}
	var httpErr events.HTTPError
	if errors.As(err, &httpErr) && httpErr.Resp != nil {
		switch httpErr.Resp.StatusCode {
		case http.StatusUnauthorized, http.StatusForbidden, http.StatusNotFound:
			return true
		}
	}
	return false
}

// backoff is exponential with jitter, capped at 5 minutes.
func backoff(attempt int) time.Duration {
	d := 2 * time.Second << min(attempt, 7)
	if d > 5*time.Minute {
		d = 5 * time.Minute
	}
	jitter := time.Duration(time.Now().UnixNano() % int64(d/4+1))
	return d + jitter
}

// scheduleReconnect is the only path for reconnects: debounced and single-flight, so wake/error signals that
// fire together collapse into one reconnect.
func (a *App) scheduleReconnect(after time.Duration) {
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.cli == nil || (a.status.Phase != PhaseReady && a.status.Phase != PhaseConnecting) {
		return
	}
	if a.reconnectTimer != nil {
		a.reconnectTimer.Stop()
	}
	a.reconnectTimer = time.AfterFunc(after, func() {
		if !a.reconnecting.CompareAndSwap(false, true) {
			return
		}
		defer a.reconnecting.Store(false)
		a.mu.Lock()
		cli, ctx := a.cli, a.runCtx
		a.mu.Unlock()
		if cli == nil || ctx.Err() != nil {
			return
		}
		a.notif.BeginCatchUp()
		if err := cli.Reconnect(ctx); err != nil {
			a.log.Warn().Err(err).Msg("Reconnect failed")
			return
		}
		a.notif.EndCatchUp(4 * time.Second)
		a.setBanner("")
		go a.refreshConversations(true)
	})
}

// client returns the connected client or an error for the UI.
func (a *App) client() (*libgm.Client, context.Context, error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.cli == nil || a.status.Phase == PhaseLogin {
		return nil, nil, errors.New("not connected")
	}
	return a.cli, a.runCtx, nil
}

func (a *App) loggedOut(reason string) {
	a.mu.Lock()
	cli := a.cli
	a.cli = nil
	if a.runStop != nil {
		a.runStop()
	}
	a.mu.Unlock()
	if cli != nil {
		cli.SetEventHandler(func(any) {})
		cli.Disconnect()
	}
	_ = storage.DeleteSession()
	a.store.Reset()
	a.mediaCache.Reset()
	a.mediaSrv.reset()
	a.avatar.Reset()
	a.notif.ClearAll()
	a.setPhase(PhaseLogin, reason)
	runtime.EventsEmit(a.ctx, "conversations", []model.Conversation{})
}

// ---------------------------------------------------------------- pairing

// SignInStep is pushed to the login screen as "signin" events.
type SignInStep struct {
	Step     string `json:"step"` // "browser", "starting", "emoji", "connecting", "error", "idle"
	Emoji    string `json:"emoji,omitempty"`
	EmojiURL string `json:"emojiUrl,omitempty"` // data: URL of the Noto emoji the phone shows (may be empty)
	Error    string `json:"error,omitempty"`
}

func (a *App) signInStep(s SignInStep) { runtime.EventsEmit(a.ctx, "signin", s) }

// StartPairing signs in with Google in a native browser window, then pairs with the phone: the user taps the
// emoji shown here on their phone. Progress is reported through "signin" events. Returns immediately.
func (a *App) StartPairing() {
	a.CancelPairing()
	ctx, stop := context.WithCancel(context.Background())
	a.mu.Lock()
	a.pairStop = stop
	a.mu.Unlock()
	go func() {
		defer stop()
		if err := a.googlePair(ctx); err != nil {
			if ctx.Err() != nil || errors.Is(err, errSignInCancelled) {
				a.signInStep(SignInStep{Step: "idle"})
				return
			}
			a.log.Warn().Err(err).Msg("Google pairing failed")
			a.signInStep(SignInStep{Step: "error", Error: pairErrorText(err)})
		}
	}()
}

func (a *App) googlePair(ctx context.Context) error {
	a.signInStep(SignInStep{Step: "browser"})
	cookies, err := googleSignIn(ctx)
	if err != nil {
		return err
	}
	signInLogf("got Google cookies (%d), contacting phone", len(cookies))
	a.signInStep(SignInStep{Step: "starting"})
	auth := libgm.NewAuthData()
	auth.SetCookies(cookies)
	cli := a.newClient(auth)
	cli.SetEventHandler(func(evt any) {})
	if err := cli.FetchConfig(ctx); err != nil {
		return fmt.Errorf("couldn't reach Google Messages: %w", err)
	}
	bgCtx, bgCancel := context.WithCancel(context.Background())
	defer bgCancel()
	emoji, ps, err := cli.StartGaiaPairing(ctx, bgCtx)
	if err != nil {
		cli.Disconnect()
		return err
	}
	signInLogf("pairing started, waiting for emoji confirmation on the phone")
	a.signInStep(SignInStep{Step: "emoji", Emoji: emoji, EmojiURL: a.fetchEmojiSVG(ctx, emoji)})
	if _, err := cli.FinishGaiaPairing(ctx, ps); err != nil {
		cli.Disconnect()
		return err
	}
	signInLogf("paired with phone")
	a.signInStep(SignInStep{Step: "connecting"})
	cli.Disconnect()
	if err := storage.SaveSession(auth); err != nil {
		a.log.Warn().Err(err).Msg("Couldn't save session")
	}
	a.notif.BeginCatchUp()
	go a.connect(auth)
	return nil
}

// fetchEmojiSVG downloads the Noto emoji image Google Messages shows, so both screens look identical.
// Falls back to the plain character (empty result) on any problem.
func (a *App) fetchEmojiSVG(ctx context.Context, emoji string) string {
	u := libgm.GetEmojiSVG(emoji)
	if !urlsafe.IsPublicHTTPS(u) || !urlsafe.IsGoogleOwned(u) {
		return ""
	}
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return ""
	}
	resp, err := a.avatar.plainHC.Do(req)
	if err != nil {
		return ""
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(io.LimitReader(resp.Body, 256<<10))
	if err != nil || resp.StatusCode != http.StatusOK || !strings.Contains(string(data[:min(len(data), 512)]), "<svg") {
		return ""
	}
	return "data:image/svg+xml;base64," + base64.StdEncoding.EncodeToString(data)
}

func pairErrorText(err error) string {
	var reqErr events.RequestError
	switch {
	case errors.Is(err, errSignInFailed):
		return "Couldn't finish signing in to Google. Try again."
	case errors.Is(err, libgm.ErrNoDevicesFound):
		return "No phone with Google Messages was found for this account. Make sure Google Messages on your phone is signed in to the same Google account."
	case errors.Is(err, libgm.ErrPairingInitTimeout):
		return "Your phone didn't respond. Make sure it's online and Google Messages is up to date."
	case errors.Is(err, libgm.ErrIncorrectEmoji):
		return "The wrong emoji was tapped on the phone. Try again."
	case errors.Is(err, libgm.ErrPairingCancelled):
		return "Pairing was cancelled on the phone."
	case errors.Is(err, libgm.ErrPairingTimeout):
		return "Pairing timed out. Try again and tap the emoji on your phone."
	case errors.Is(err, events.ErrCallerNoPermission):
		return "Google refused the request for this account (no permission)."
	case errors.As(err, &reqErr) && reqErr.Data != nil:
		return fmt.Sprintf("Google returned an error (%d). Try again.", reqErr.Data.Type)
	}
	return "Pairing failed: " + err.Error()
}

func (a *App) CancelPairing() {
	a.mu.Lock()
	stop := a.pairStop
	a.pairStop = nil
	a.mu.Unlock()
	if stop != nil {
		stop()
	}
}

// Logout unpairs this computer from the phone and forgets the session.
func (a *App) Logout() {
	if cli, ctx, err := a.client(); err == nil {
		if err := cli.Unpair(ctx); err != nil {
			a.log.Warn().Err(err).Msg("Unpair failed")
		}
	}
	a.loggedOut("")
}

// ---------------------------------------------------------------- events from libgm

// handleEvent is called synchronously by libgm and must never block on requests.
func (a *App) handleEvent(raw any) {
	switch evt := raw.(type) {
	case *events.AuthTokenRefreshed:
		a.mu.Lock()
		cli := a.cli
		a.mu.Unlock()
		if cli != nil {
			_ = storage.SaveSession(cli.AuthData)
		}
	case *events.ListenFatalError:
		a.log.Error().Err(evt.Error).Msg("Fatal listen error")
		if isAuthError(evt.Error) {
			go a.loggedOut("Your session expired. Pair your phone again.")
		} else {
			a.setBanner("Disconnected from Google Messages.")
			a.scheduleReconnect(5 * time.Second)
		}
	case *events.ListenTemporaryError:
		if !a.asleep.Load() {
			a.setBanner("Connection problem. Reconnecting…")
		}
		a.notif.BeginCatchUp()
	case *events.ListenRecovered:
		a.setBanner("")
		a.notif.EndCatchUp(4 * time.Second)
		go a.refreshConversations(false)
	case *events.PhoneNotResponding:
		a.setBanner("Your phone isn't responding. Make sure it's online.")
	case *events.PhoneRespondingAgain:
		a.setBanner("")
	case *events.PingFailed:
		a.log.Warn().Err(evt.Error).Msg("Ping failed")
	case *events.GaiaLoggedOut:
		go a.loggedOut("You were signed out from the phone.")
	case *gmproto.RevokePairData:
		go a.loggedOut("This computer was unpaired from your phone.")
	case *gmproto.UserAlertEvent:
		a.handleUserAlert(evt)
	case *gmproto.Settings:
		a.mu.Lock()
		a.sims = evt.GetSIMCards()
		a.mu.Unlock()
	case *gmproto.Conversation:
		a.store.UpsertConversation(model.ConvertConversation(evt))
		a.avatar.RequestFor(model.ConvertConversation(evt))
		a.emitConversations()
	case *libgm.WrappedMessage:
		a.receive(evt.Message, evt.IsOld)
	case *gmproto.TypingData:
		runtime.EventsEmit(a.ctx, "typing", map[string]any{
			"conversationId": evt.GetConversationID(),
			"typing":         evt.GetType() == gmproto.TypingTypes_STARTED_TYPING,
		})
	}
}

func (a *App) handleUserAlert(evt *gmproto.UserAlertEvent) {
	switch evt.GetAlertType() {
	case gmproto.AlertType_BROWSER_INACTIVE, gmproto.AlertType_BROWSER_INACTIVE_FROM_TIMEOUT,
		gmproto.AlertType_BROWSER_INACTIVE_FROM_INACTIVITY:
		a.mu.Lock()
		a.status.Inactive = true
		a.mu.Unlock()
		a.emitStatus()
	case gmproto.AlertType_BROWSER_ACTIVE:
		a.mu.Lock()
		was := a.status.Inactive
		a.status.Inactive = false
		a.mu.Unlock()
		a.emitStatus()
		if was {
			go a.refreshConversations(true)
		}
	case gmproto.AlertType_MOBILE_DATABASE_SYNC_COMPLETE:
		go a.refreshConversations(true)
	}
}

// UseHere makes this client the active Messages for web session again.
func (a *App) UseHere() error {
	cli, ctx, err := a.client()
	if err != nil {
		return err
	}
	return cli.SetActiveSession(ctx)
}

func (a *App) receive(m *gmproto.Message, isOld bool) {
	conv, _ := a.store.Conversation(m.GetConversationID())
	vm := model.ConvertMessage(m, conv.MyID)
	r := a.store.Receive(vm, isOld, time.Now())
	if r.MessagesChanged {
		a.emitMessages(vm.ConversationID)
	}
	if r.ConvChanged {
		a.emitConversations()
	}
	if r.FetchConv {
		go a.fetchConversation(vm.ConversationID)
	}
	if r.MarkRead != "" {
		a.scheduleMarkRead(vm.ConversationID, r.MarkRead)
	}
	if r.Alert != nil {
		a.notif.Enqueue(*r.Alert)
	}
}

func (a *App) fetchConversation(cid string) {
	a.mu.Lock()
	if a.fetchingConv[cid] {
		a.mu.Unlock()
		return
	}
	a.fetchingConv[cid] = true
	a.mu.Unlock()
	defer func() {
		a.mu.Lock()
		delete(a.fetchingConv, cid)
		a.mu.Unlock()
	}()
	cli, ctx, err := a.client()
	if err != nil {
		return
	}
	c, err := cli.GetConversation(ctx, cid)
	if err != nil || c.GetConversationID() == "" {
		return
	}
	vm := model.ConvertConversation(c)
	a.store.UpsertConversation(vm)
	a.avatar.RequestFor(vm)
	a.emitConversations()
}

// refreshConversations reloads the inbox and archive. Throttled to once per 30 s unless forced.
func (a *App) refreshConversations(force bool) {
	a.mu.Lock()
	if !force && time.Since(a.lastListFetch) < 30*time.Second {
		a.mu.Unlock()
		return
	}
	a.lastListFetch = time.Now()
	a.mu.Unlock()
	cli, ctx, err := a.client()
	if err != nil {
		return
	}
	for _, folder := range []gmproto.ListConversationsRequest_Folder{gmproto.ListConversationsRequest_INBOX, gmproto.ListConversationsRequest_ARCHIVE} {
		resp, err := cli.ListConversations(ctx, &gmproto.ListConversationsRequest{Count: 100, Folder: folder})
		if err != nil {
			a.log.Warn().Err(err).Msg("ListConversations failed")
			continue
		}
		for _, c := range resp.GetConversations() {
			vm := model.ConvertConversation(c)
			a.store.UpsertConversation(vm)
			a.avatar.RequestFor(vm)
		}
	}
	a.emitConversations()
}

// emitConversations is debounced so a burst of updates becomes one UI refresh.
func (a *App) emitConversations() {
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.convEmit != nil {
		return
	}
	a.convEmit = time.AfterFunc(120*time.Millisecond, func() {
		a.mu.Lock()
		a.convEmit = nil
		a.mu.Unlock()
		runtime.EventsEmit(a.ctx, "conversations", a.store.Conversations())
		a.emitStatus()
	})
}

func (a *App) emitMessages(cid string) {
	runtime.EventsEmit(a.ctx, "messages", map[string]any{"conversationId": cid, "messages": a.store.Messages(cid)})
}

// ---------------------------------------------------------------- notification actions

func (a *App) onNotificationResponse(res runtime.NotificationResult) {
	if res.Error != nil {
		return
	}
	r := res.Response
	cid, _ := r.UserInfo["conversationId"].(string)
	switch r.ActionIdentifier {
	case notifActionReply:
		if cid != "" && strings.TrimSpace(r.UserText) != "" {
			go func() { _ = a.SendText(cid, r.UserText, "") }()
		}
	case notifActionMarkRead:
		if cid != "" {
			go a.MarkRead(cid)
		}
	default:
		runtime.WindowUnminimise(a.ctx)
		runtime.WindowShow(a.ctx)
		if cid != "" {
			runtime.EventsEmit(a.ctx, "open-conversation", cid)
		}
	}
}

// ---------------------------------------------------------------- bound API: conversations

func (a *App) Conversations() []model.Conversation { return a.store.Conversations() }

// SetViewing tells the backend which chat is open and whether the window is focused (for read state and
// whether to alert).
func (a *App) SetViewing(cid string, focused bool) {
	a.store.SetViewing(cid, focused)
	if cid != "" && focused {
		a.notif.Clear(cid)
		if c, ok := a.store.Conversation(cid); ok && c.Unread {
			go a.MarkRead(cid)
		}
	}
}

// OpenConversation returns the loaded messages, fetching the first page if needed.
func (a *App) OpenConversation(cid string) ([]model.Message, error) {
	if !a.store.IsTracked(cid) {
		if _, err := a.LoadOlder(cid); err != nil {
			return nil, err
		}
	}
	return a.store.Messages(cid), nil
}

// LoadOlder fetches the previous page. Returns false when there is nothing more. Concurrent calls for the
// same conversation share one request (opening a chat and scrolling can both ask at once).
func (a *App) LoadOlder(cid string) (bool, error) {
	a.mu.Lock()
	if a.loading == nil {
		a.loading = map[string]chan struct{}{}
	}
	if ch, busy := a.loading[cid]; busy {
		a.mu.Unlock()
		<-ch
		return !a.store.Cursor(cid).Done, nil
	}
	ch := make(chan struct{})
	a.loading[cid] = ch
	a.mu.Unlock()
	defer func() {
		a.mu.Lock()
		delete(a.loading, cid)
		a.mu.Unlock()
		close(ch)
	}()
	more, err := a.loadPage(cid)
	if err != nil {
		a.log.Warn().Err(err).Str("conversation", cid).Msg("Loading messages failed")
	}
	return more, err
}

func (a *App) loadPage(cid string) (bool, error) {
	cur := a.store.Cursor(cid)
	if cur.Done {
		return false, nil
	}
	first := cur.LastItemID == ""
	var gc *gmproto.Cursor
	if !first {
		gc = &gmproto.Cursor{LastItemID: cur.LastItemID, LastItemTimestamp: cur.LastItemTimestamp}
	}
	// Right after connecting the phone sometimes answers the first page with nothing; retry a few times
	// before believing the conversation is empty.
	var resp *gmproto.ListMessagesResponse
	for attempt := 0; ; attempt++ {
		cli, runCtx, err := a.client()
		if err != nil {
			return false, err
		}
		ctx, cancel := context.WithTimeout(runCtx, 45*time.Second)
		resp, err = cli.FetchMessages(ctx, cid, pageSize, gc)
		cancel()
		if err != nil {
			return false, err
		}
		if len(resp.GetMessages()) > 0 || !first || attempt >= 3 {
			break
		}
		a.log.Info().Str("conversation", cid).Int("attempt", attempt+1).Msg("Phone returned no messages, retrying")
		time.Sleep(time.Duration(attempt+1) * 1500 * time.Millisecond)
	}
	conv, _ := a.store.Conversation(cid)
	msgs := make([]model.Message, 0, len(resp.GetMessages()))
	for _, m := range resp.GetMessages() {
		msgs = append(msgs, model.ConvertMessage(m, conv.MyID))
	}
	a.store.AddHistory(cid, msgs)
	next := resp.GetCursor()
	done := next.GetLastItemID() == "" || len(msgs) == 0
	a.store.SetCursor(cid, model.Cursor{LastItemID: next.GetLastItemID(), LastItemTimestamp: next.GetLastItemTimestamp(), Done: done})
	a.emitMessages(cid)
	return !done, nil
}

// MarkRead marks the conversation read on the phone (debounced per conversation).
func (a *App) MarkRead(cid string) {
	id := a.store.LatestIncomingID(cid)
	if id == "" {
		if c, ok := a.store.Conversation(cid); ok {
			id = c.LatestMsgID
		}
	}
	if id != "" {
		a.scheduleMarkRead(cid, id)
	}
	if a.store.SetUnread(cid, false) {
		a.emitConversations()
	}
	a.notif.Clear(cid)
}

func (a *App) scheduleMarkRead(cid, msgID string) {
	a.mu.Lock()
	defer a.mu.Unlock()
	if t := a.markReadTimer[cid]; t != nil {
		t.Stop()
	}
	a.markReadTimer[cid] = time.AfterFunc(800*time.Millisecond, func() {
		a.mu.Lock()
		delete(a.markReadTimer, cid)
		a.mu.Unlock()
		if cli, ctx, err := a.client(); err == nil {
			if err := cli.MarkRead(ctx, cid, msgID); err != nil {
				a.log.Warn().Err(err).Msg("MarkRead failed")
			}
		}
	})
}

// StartConversation opens (or creates) a chat with the given phone numbers.
func (a *App) StartConversation(numbers []string) (string, error) {
	cli, ctx, err := a.client()
	if err != nil {
		return "", err
	}
	var nums []*gmproto.ContactNumber
	for _, n := range numbers {
		n = strings.TrimSpace(n)
		if n == "" {
			continue
		}
		nums = append(nums, &gmproto.ContactNumber{MysteriousInt: 7, Number: n, Number2: n})
	}
	if len(nums) == 0 {
		return "", errors.New("enter a phone number")
	}
	resp, err := cli.GetOrCreateConversation(ctx, &gmproto.GetOrCreateConversationRequest{Numbers: nums})
	if err != nil {
		return "", err
	}
	c := resp.GetConversation()
	if c.GetConversationID() == "" {
		return "", fmt.Errorf("the phone couldn't start that conversation (%s)", resp.GetStatus())
	}
	vm := model.ConvertConversation(c)
	a.store.UpsertConversation(vm)
	a.avatar.RequestFor(vm)
	a.emitConversations()
	return vm.ID, nil
}

// SetTyping tells the other side we're typing (throttled).
func (a *App) SetTyping(cid string) {
	a.mu.Lock()
	if time.Since(a.typingSentAt[cid]) < 5*time.Second {
		a.mu.Unlock()
		return
	}
	a.typingSentAt[cid] = time.Now()
	a.mu.Unlock()
	go func() {
		if cli, ctx, err := a.client(); err == nil {
			_ = cli.SetTyping(ctx, cid, a.simFor(cid))
		}
	}()
}

// HideAlerts toggles local notification muting for a conversation (mute state can't be read from the phone).
// SetArchived archives or unarchives a conversation on the phone.
func (a *App) SetArchived(cid string, archived bool) error {
	cli, ctx, err := a.client()
	if err != nil {
		return err
	}
	status := gmproto.ConversationStatus_ACTIVE
	if archived {
		status = gmproto.ConversationStatus_ARCHIVED
	}
	resp, err := cli.UpdateConversation(ctx, &gmproto.UpdateConversationRequest{
		ConversationID: cid,
		Data: &gmproto.UpdateConversationRequest_UpdateData{UpdateData: &gmproto.UpdateConversationData{
			ConversationID: cid,
			Data:           &gmproto.UpdateConversationData_Status{Status: status},
		}},
	})
	if err == nil && !resp.GetSuccess() {
		err = errors.New("the phone couldn't update the conversation")
	}
	if err != nil {
		a.log.Warn().Err(err).Bool("archive", archived).Msg("Archive failed")
		return err
	}
	if a.store.SetArchived(cid, archived) {
		a.emitConversations()
	}
	return nil
}

// DeleteConversation deletes a conversation on the phone (like deleting it in Google Messages).
func (a *App) DeleteConversation(cid string) error {
	cli, ctx, err := a.client()
	if err != nil {
		return err
	}
	conv, _ := a.store.Conversation(cid)
	phone := ""
	if !conv.IsGroup && len(conv.Numbers) == 1 {
		phone = conv.Numbers[0]
	}
	if err := cli.DeleteConversation(ctx, cid, phone); err != nil {
		a.log.Warn().Err(err).Msg("Delete conversation failed")
		return err
	}
	a.store.RemoveConversation(cid)
	a.emitConversations()
	return nil
}

// Contact is a phone contact for the new-message picker.
type Contact struct {
	Name   string `json:"name"`
	Number string `json:"number"` // as shown (formatted)
	Raw    string `json:"raw"`    // as sent to the phone
	Color  string `json:"color"`
}

// Contacts lists the phone's contacts (fetched on demand, kept in memory only).
func (a *App) Contacts() ([]Contact, error) {
	cli, ctx, err := a.client()
	if err != nil {
		return nil, err
	}
	resp, err := cli.ListContacts(ctx)
	if err != nil {
		a.log.Warn().Err(err).Msg("Listing contacts failed")
		return nil, err
	}
	out := make([]Contact, 0, len(resp.GetContacts()))
	seen := map[string]bool{}
	for _, c := range resp.GetContacts() {
		raw := c.GetNumber().GetNumber()
		if raw == "" {
			raw = c.GetNumber().GetNumber2()
		}
		if raw == "" || seen[c.GetName()+"\x00"+raw] {
			continue
		}
		seen[c.GetName()+"\x00"+raw] = true
		shown := c.GetNumber().GetFormattedNumber()
		if shown == "" {
			shown = raw
		}
		out = append(out, Contact{Name: c.GetName(), Number: shown, Raw: raw, Color: c.GetAvatarHexColor()})
	}
	sort.SliceStable(out, func(i, j int) bool { return strings.ToLower(out[i].Name) < strings.ToLower(out[j].Name) })
	return out, nil
}

func (a *App) HideAlerts(cid string, hide bool) {
	a.mu.Lock()
	if hide {
		a.prefs.HiddenAlerts[cid] = true
	} else {
		delete(a.prefs.HiddenAlerts, cid)
	}
	p := a.prefs
	a.mu.Unlock()
	_ = storage.SavePrefs(p)
}

func (a *App) GetPrefs() storage.Prefs {
	a.mu.Lock()
	defer a.mu.Unlock()
	return a.prefs
}

func (a *App) SetPrefs(p storage.Prefs) error {
	a.mu.Lock()
	if p.HiddenAlerts == nil {
		p.HiddenAlerts = a.prefs.HiddenAlerts
	}
	switch p.LinkPreviews {
	case "everyone", "contacts", "off":
	default:
		p.LinkPreviews = "contacts"
	}
	a.prefs = p
	a.mu.Unlock()
	return storage.SavePrefs(p)
}

// ---------------------------------------------------------------- bound API: sending

func (a *App) simFor(cid string) *gmproto.SIMPayload {
	conv, _ := a.store.Conversation(cid)
	a.mu.Lock()
	defer a.mu.Unlock()
	for _, s := range a.sims {
		if s.GetSIMParticipant().GetID() == conv.MyID {
			return s.GetSIMData().GetSIMPayload()
		}
	}
	if len(a.sims) > 0 {
		return a.sims[0].GetSIMData().GetSIMPayload()
	}
	return nil
}

func (a *App) baseRequest(cid, tmpID, replyTo string) *gmproto.SendMessageRequest {
	conv, _ := a.store.Conversation(cid)
	req := &gmproto.SendMessageRequest{
		ConversationID: cid,
		MessagePayload: &gmproto.MessagePayload{
			TmpID:          tmpID,
			ConversationID: cid,
			ParticipantID:  conv.MyID,
			TmpID2:         tmpID,
		},
		SIMPayload: a.simFor(cid),
		TmpID:      tmpID,
	}
	// Replies are an RCS feature: like mautrix-gmessages, SMS/MMS chats get a plain message (the phone can reject
	// SMS sends that carry reply metadata).
	if replyTo != "" && conv.IsRCS && !strings.HasPrefix(replyTo, "tmp_") {
		req.Reply = &gmproto.ReplyPayload{MessageID: replyTo}
	}
	return req
}

// SendText sends a text message with an optimistic local copy.
func (a *App) SendText(cid, text, replyTo string) error {
	text = strings.TrimRight(text, " \t\r\n")
	if strings.TrimSpace(text) == "" {
		return nil
	}
	tmpID := util.GenerateTmpID()
	a.store.AddLocal(model.NewLocalMessage(text, tmpID, cid, replyTo, 0, time.Now()))
	a.emitMessages(cid)
	a.emitConversations()
	req := a.baseRequest(cid, tmpID, replyTo)
	req.MessagePayload.MessageInfo = []*gmproto.MessageInfo{{
		Data: &gmproto.MessageInfo_MessageContent{MessageContent: &gmproto.MessageContent{Content: text}},
	}}
	return a.send(cid, tmpID, req)
}

func (a *App) send(cid, tmpID string, req *gmproto.SendMessageRequest) error {
	cli, ctx, err := a.client()
	if err == nil {
		var resp *gmproto.SendMessageResponse
		resp, err = cli.SendMessage(ctx, req)
		if errors.Is(err, libgm.ErrPhoneNotResponding) {
			// The server accepted it; the phone may still send it when it comes back online.
			return nil
		}
		if err == nil && resp.GetStatus() != gmproto.SendMessageResponse_SUCCESS {
			err = fmt.Errorf("the phone rejected the message (%s)", resp.GetStatus())
		}
	}
	if err != nil {
		a.log.Warn().Err(err).Bool("reply", req.Reply != nil).Msg("Send failed")
		a.store.FailLocal(cid, tmpID)
		a.emitMessages(cid)
	}
	return err
}

// PickAndSendFiles shows a file picker and sends each chosen file.
func (a *App) PickAndSendFiles(cid string) error {
	paths, err := runtime.OpenMultipleFilesDialog(a.ctx, runtime.OpenDialogOptions{Title: "Choose attachments"})
	if err != nil || len(paths) == 0 {
		return err
	}
	return a.SendFiles(cid, paths)
}

// SendFiles sends local files (from the picker or a drag-and-drop) as attachments.
func (a *App) SendFiles(cid string, paths []string) error {
	var firstErr error
	for _, p := range paths {
		data, err := readCapped(p, maxAttachmentBytes)
		if err != nil {
			firstErr = cmpErr(firstErr, fmt.Errorf("%s: %w", filepath.Base(p), err))
			continue
		}
		if err := a.sendAttachment(cid, filepath.Base(p), "", data); err != nil {
			firstErr = cmpErr(firstErr, err)
		}
	}
	return firstErr
}

// SendFileData sends an attachment supplied by the frontend (pasted image, voice recording), base64-encoded.
func (a *App) SendFileData(cid, name, mime, b64 string) error {
	if base64.StdEncoding.DecodedLen(len(b64)) > maxAttachmentBytes {
		return errors.New("attachment is too large (100 MB max)")
	}
	data, err := base64.StdEncoding.DecodeString(b64)
	if err != nil {
		return err
	}
	return a.sendAttachment(cid, name, mime, data)
}

func (a *App) sendAttachment(cid, name, mime string, data []byte) error {
	if len(data) == 0 {
		return errors.New("file is empty")
	}
	if mime == "" || mime == "application/octet-stream" {
		mime = detectMime(name, data)
	}
	name = sanitizeFilename(name)
	tmpID := util.GenerateTmpID()
	local := model.NewLocalMessage("", tmpID, cid, "", 1, time.Now())
	local.Media = []model.Media{{Mime: mime, Name: name, Size: int64(len(data))}}
	a.store.AddLocal(local)
	a.emitMessages(cid)
	cli, _, err := a.client()
	if err != nil {
		a.store.FailLocal(cid, tmpID)
		a.emitMessages(cid)
		return err
	}
	media, err := cli.UploadMedia(data, name, mime)
	if err != nil {
		a.store.FailLocal(cid, tmpID)
		a.emitMessages(cid)
		a.log.Warn().Err(err).Str("mime", mime).Msg("Upload failed")
		return fmt.Errorf("upload failed: %w", err)
	}
	req := a.baseRequest(cid, tmpID, "")
	req.MessagePayload.MessageInfo = []*gmproto.MessageInfo{{Data: &gmproto.MessageInfo_MediaContent{MediaContent: media}}}
	return a.send(cid, tmpID, req)
}

// React adds, switches or removes a tapback.
func (a *App) React(cid, msgID, emoji string, remove bool) error {
	cli, ctx, err := a.client()
	if err != nil {
		return err
	}
	action := gmproto.SendReactionRequest_ADD
	if remove {
		action = gmproto.SendReactionRequest_REMOVE
	} else {
		for _, m := range a.store.Messages(cid) {
			if m.ID == msgID {
				for _, r := range m.Reactions {
					if r.ByMe {
						action = gmproto.SendReactionRequest_SWITCH
					}
				}
			}
		}
	}
	if strings.HasPrefix(msgID, "tmp_") {
		return errors.New("wait for the message to finish sending")
	}
	resp, err := cli.SendReaction(ctx, &gmproto.SendReactionRequest{
		MessageID: msgID, ReactionData: gmproto.MakeReactionData(emoji), Action: action, SIMPayload: a.simFor(cid),
	})
	if err == nil && !resp.GetSuccess() {
		err = errors.New("the phone rejected the reaction")
	}
	if err != nil {
		a.log.Warn().Err(err).Str("action", action.String()).Msg("Reaction failed")
	}
	return err
}

// DeleteMessage deletes a message on the phone.
func (a *App) DeleteMessage(cid, msgID string) error {
	if strings.HasPrefix(msgID, "tmp_") {
		a.store.RemoveMessage(cid, msgID)
		a.emitMessages(cid)
		return nil
	}
	cli, ctx, err := a.client()
	if err != nil {
		return err
	}
	resp, err := cli.DeleteMessage(ctx, msgID)
	if err != nil {
		a.log.Warn().Err(err).Msg("Delete failed")
		return err
	}
	if !resp.GetSuccess() {
		return errors.New("the phone couldn't delete the message")
	}
	a.store.RemoveMessage(cid, msgID)
	a.emitMessages(cid)
	return nil
}

// ---------------------------------------------------------------- bound API: media and links

// GetMedia downloads and decrypts an attachment into memory and returns a /media/ URL the webview can load.
func (a *App) GetMedia(mediaID, keyB64, mime string) (string, error) {
	if mediaID == "" {
		return "", errors.New("no media")
	}
	key, err := base64.StdEncoding.DecodeString(keyB64)
	if err != nil {
		return "", errors.New("invalid media key")
	}
	ref := mediaRef{id: mediaID, key: key, mime: mime}
	a.log.Info().Str("mime", mime).Int("key_len", len(key)).Bool("inline", strings.HasPrefix(mediaID, model.InlineMediaIDPrefix)).Msg("Loading attachment")
	if _, err := a.media(a.ctx, ref); err != nil {
		a.log.Warn().Err(err).Str("mime", mime).Msg("Couldn't download attachment")
		return "", err
	}
	return mediaPathPrefix + a.mediaSrv.register(ref), nil
}

// SaveMedia asks where to save an attachment and writes it there.
func (a *App) SaveMedia(mediaID, keyB64, name string) error {
	key, err := base64.StdEncoding.DecodeString(keyB64)
	if err != nil {
		return errors.New("invalid media key")
	}
	data, err := a.media(a.ctx, mediaRef{id: mediaID, key: key})
	if err != nil {
		a.log.Warn().Err(err).Msg("Couldn't download attachment to save")
		return err
	}
	path, err := runtime.SaveFileDialog(a.ctx, runtime.SaveDialogOptions{Title: "Save attachment", DefaultFilename: sanitizeFilename(name)})
	if err != nil || path == "" {
		return err
	}
	return os.WriteFile(path, data, 0o644)
}

// OpenLink opens a link from a message in the default browser, only for allow-listed schemes.
func (a *App) OpenLink(u string) {
	if urlsafe.IsOpenableLink(u) {
		runtime.BrowserOpenURL(a.ctx, u)
	}
}

// Avatar returns a cached avatar data URL ("" if not loaded yet; it then arrives as an "avatar" event).
func (a *App) Avatar(key string) string { return a.avatar.Get(key) }

// ---------------------------------------------------------------- helpers

func dataURL(mime string, data []byte) string {
	if mime == "" || strings.ContainsAny(mime, ";,\"' <>") {
		mime = http.DetectContentType(data)
		if i := strings.IndexByte(mime, ';'); i >= 0 {
			mime = mime[:i]
		}
	}
	return "data:" + mime + ";base64," + base64.StdEncoding.EncodeToString(data)
}

func readCapped(path string, max int64) ([]byte, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	st, err := f.Stat()
	if err != nil {
		return nil, err
	}
	if st.IsDir() {
		return nil, errors.New("folders can't be sent")
	}
	if st.Size() > max {
		return nil, errors.New("file is too large (100 MB max)")
	}
	return io.ReadAll(io.LimitReader(f, max))
}

func cmpErr(first, next error) error {
	if first != nil {
		return first
	}
	return next
}

func hasSubtitleSupport() bool { return goruntime.GOOS != "windows" }

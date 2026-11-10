package main

import (
	"context"
	"sync"
	"time"

	"github.com/wailsapp/wails/v2/pkg/runtime"

	"github.com/goobmessages/desktop/internal/model"
)

const (
	notifCategoryMessage = "GOOB_MESSAGE"
	notifActionReply     = "GOOB_REPLY"
	notifActionMarkRead  = "GOOB_MARK_READ"
)

// Notifier buffers alerts, applies model.Plan and posts native notifications (D-Bus on Linux, toasts on
// Windows). Never post one notification per message: bursts (e.g. the backlog after the computer wakes)
// become one or a few notifications.
type Notifier struct {
	ctx       context.Context
	available bool
	prefs     func() (enabled, previews bool, hidden map[string]bool)

	mu       sync.Mutex
	pending  []model.Alert
	firstAt  time.Time
	flush    *time.Timer
	catchUp  bool
	catchUpT *time.Timer
	posted   map[string]bool
}

func NewNotifier(prefs func() (bool, bool, map[string]bool)) *Notifier {
	return &Notifier{prefs: prefs, posted: map[string]bool{}}
}

func (n *Notifier) Start(ctx context.Context) {
	n.ctx = ctx
	if err := runtime.InitializeNotifications(ctx); err != nil {
		runtime.LogWarningf(ctx, "notifications unavailable: %v", err)
		return
	}
	n.available = runtime.IsNotificationAvailable(ctx)
	if !n.available {
		return
	}
	if ok, _ := runtime.CheckNotificationAuthorization(ctx); !ok {
		_, _ = runtime.RequestNotificationAuthorization(ctx)
	}
	_ = runtime.RegisterNotificationCategory(ctx, runtime.NotificationCategory{
		ID: notifCategoryMessage,
		Actions: []runtime.NotificationAction{
			{ID: notifActionMarkRead, Title: "Mark as Read"},
		},
		HasReplyField:    true,
		ReplyPlaceholder: "Message",
		ReplyButtonTitle: "Send",
	})
}

func (n *Notifier) Stop() {
	if n.available {
		runtime.CleanupNotifications(n.ctx)
	}
}

func (n *Notifier) Enqueue(a model.Alert) {
	enabled, _, hidden := n.prefs()
	if !n.available || !enabled || hidden[a.ConversationID] {
		return
	}
	n.mu.Lock()
	defer n.mu.Unlock()
	n.pending = append(n.pending, a)
	if n.firstAt.IsZero() {
		n.firstAt = time.Now()
	}
	n.scheduleLocked()
}

// BeginCatchUp holds alerts (launch, wake, reconnect); they are summarised when catch-up ends.
func (n *Notifier) BeginCatchUp() {
	n.mu.Lock()
	defer n.mu.Unlock()
	n.catchUp = true
	if n.flush != nil {
		n.flush.Stop()
	}
	n.resetCatchUpTimerLocked(45 * time.Second) // safety net: never hold alerts forever
}

// EndCatchUp waits briefly for the backlog to finish arriving, then flushes as a summary.
func (n *Notifier) EndCatchUp(after time.Duration) {
	n.mu.Lock()
	defer n.mu.Unlock()
	if !n.catchUp {
		return
	}
	n.resetCatchUpTimerLocked(after)
}

func (n *Notifier) resetCatchUpTimerLocked(d time.Duration) {
	if n.catchUpT != nil {
		n.catchUpT.Stop()
	}
	n.catchUpT = time.AfterFunc(d, func() {
		n.mu.Lock()
		if !n.catchUp {
			n.mu.Unlock()
			return
		}
		n.catchUp = false
		n.mu.Unlock()
		n.doFlush(true)
	})
}

func (n *Notifier) scheduleLocked() {
	if n.catchUp {
		return
	}
	if n.flush != nil {
		n.flush.Stop()
	}
	delay := time.Second // 1 s debounce, but never delay an alert more than ~3 s
	if time.Since(n.firstAt) >= 3*time.Second {
		delay = 0
	}
	n.flush = time.AfterFunc(delay, func() { n.doFlush(false) })
}

func (n *Notifier) doFlush(catchUp bool) {
	n.mu.Lock()
	alerts := n.pending
	n.pending = nil
	n.firstAt = time.Time{}
	n.mu.Unlock()
	_, previews, _ := n.prefs()
	for _, p := range model.Plan(alerts, catchUp, time.Now(), previews) {
		n.post(p)
	}
}

func (n *Notifier) post(p model.Planned) {
	n.mu.Lock()
	replace := n.posted[p.ID]
	n.posted[p.ID] = true
	n.mu.Unlock()
	if replace {
		_ = runtime.RemoveNotification(n.ctx, p.ID) // a newer alert replaces the conversation's banner
	}
	opts := runtime.NotificationOptions{ID: p.ID, Title: p.Title, Subtitle: p.Subtitle, Body: p.Body}
	if p.Subtitle != "" && !hasSubtitleSupport() {
		opts.Body = p.Subtitle + "\n" + p.Body
	}
	var err error
	if p.ConversationID != "" {
		opts.Data = map[string]any{"conversationId": p.ConversationID}
		opts.CategoryID = notifCategoryMessage
		err = runtime.SendNotificationWithActions(n.ctx, opts)
	} else {
		err = runtime.SendNotification(n.ctx, opts)
	}
	if err != nil {
		runtime.LogWarningf(n.ctx, "notification failed: %v", err)
	}
}

// Clear removes pending and delivered alerts for a conversation (it was opened or read).
func (n *Notifier) Clear(convID string) {
	id := model.NotificationID(convID)
	n.mu.Lock()
	kept := n.pending[:0]
	for _, a := range n.pending {
		if a.ConversationID != convID {
			kept = append(kept, a)
		}
	}
	n.pending = kept
	wasPosted := n.posted[id]
	delete(n.posted, id)
	n.mu.Unlock()
	if n.available && wasPosted {
		_ = runtime.RemoveNotification(n.ctx, id)
	}
}

func (n *Notifier) ClearAll() {
	n.mu.Lock()
	n.pending = nil
	n.posted = map[string]bool{}
	n.mu.Unlock()
	if n.available {
		_ = runtime.RemoveAllDeliveredNotifications(n.ctx)
	}
}

package model

import (
	"sort"
	"sync"
	"time"
)

// Store is the in-memory state (nothing is cached to disk). Safe for concurrent use.
type Store struct {
	mu            sync.Mutex
	convs         map[string]Conversation
	messages      map[string][]Message // only conversations that were opened are tracked
	cursors       map[string]Cursor
	notified      map[string]bool
	notifiedOrder []string
	selectedID    string
	focused       bool
}

// Cursor marks where to continue loading older messages.
type Cursor struct {
	LastItemID        string
	LastItemTimestamp int64
	Done              bool
}

func NewStore() *Store {
	return &Store{
		convs:    map[string]Conversation{},
		messages: map[string][]Message{},
		cursors:  map[string]Cursor{},
		notified: map[string]bool{},
	}
}

func (s *Store) Reset() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.convs = map[string]Conversation{}
	s.messages = map[string][]Message{}
	s.cursors = map[string]Cursor{}
	s.selectedID = ""
}

// SetViewing records which conversation is open and whether the window has focus.
func (s *Store) SetViewing(convID string, focused bool) {
	s.mu.Lock()
	s.selectedID, s.focused = convID, focused
	s.mu.Unlock()
}

func (s *Store) isViewing(cid string) bool { return s.focused && s.selectedID == cid }

// UpsertConversation stores c. The phone sends pinned chats twice in lists; keying by id dedupes them.
// Conversations the phone reports as deleted / spam / blocked / trashed are removed instead.
func (s *Store) UpsertConversation(c Conversation) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if c.Hidden {
		s.removeLocked(c.ID)
		return
	}
	if old, ok := s.convs[c.ID]; ok {
		if s.isViewing(c.ID) {
			c.Unread = false
		}
		// The list RPC's preview can lag behind a message we already received.
		if old.Timestamp > c.Timestamp {
			c.Timestamp, c.Preview = old.Timestamp, old.Preview
		}
	}
	s.convs[c.ID] = c
}

// RemoveConversation forgets a conversation and its loaded messages.
func (s *Store) RemoveConversation(id string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.removeLocked(id)
}

func (s *Store) removeLocked(id string) {
	delete(s.convs, id)
	delete(s.messages, id)
	delete(s.cursors, id)
}

// SetArchived updates the local archived flag (the phone confirms with a conversation update).
func (s *Store) SetArchived(id string, archived bool) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	c, ok := s.convs[id]
	if !ok {
		return false
	}
	c.Archived = archived
	s.convs[id] = c
	return true
}

func (s *Store) Conversation(id string) (Conversation, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	c, ok := s.convs[id]
	return c, ok
}

func (s *Store) SetUnread(id string, unread bool) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	c, ok := s.convs[id]
	if !ok || c.Unread == unread {
		return false
	}
	c.Unread = unread
	s.convs[id] = c
	return true
}

// Conversations returns all conversations, pinned first, then newest first.
func (s *Store) Conversations() []Conversation {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := make([]Conversation, 0, len(s.convs))
	for _, c := range s.convs {
		out = append(out, c)
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].Pinned != out[j].Pinned {
			return out[i].Pinned
		}
		if out[i].Timestamp != out[j].Timestamp {
			return out[i].Timestamp > out[j].Timestamp
		}
		return out[i].ID < out[j].ID
	})
	return out
}

func (s *Store) UnreadCount() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	n := 0
	for _, c := range s.convs {
		if c.Unread && !c.Archived {
			n++
		}
	}
	return n
}

func (s *Store) Messages(cid string) []Message {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]Message(nil), s.messages[cid]...)
}

func (s *Store) IsTracked(cid string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	_, ok := s.messages[cid]
	return ok
}

func (s *Store) Cursor(cid string) Cursor {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.cursors[cid]
}

func (s *Store) SetCursor(cid string, c Cursor) {
	s.mu.Lock()
	s.cursors[cid] = c
	s.mu.Unlock()
}

// AddHistory merges a page of fetched messages into a conversation (and starts tracking it).
func (s *Store) AddHistory(cid string, msgs []Message) {
	s.mu.Lock()
	defer s.mu.Unlock()
	list := s.messages[cid]
	for _, m := range msgs {
		list = mergeInto(list, m)
	}
	s.messages[cid] = normalize(list)
}

// AddLocal appends an optimistic outgoing message.
func (s *Store) AddLocal(m Message) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.messages[m.ConversationID] = normalize(append(s.messages[m.ConversationID], m))
	if c, ok := s.convs[m.ConversationID]; ok {
		c.Preview, c.Timestamp = m.Summary(), maxI(c.Timestamp, m.Timestamp)
		s.convs[m.ConversationID] = c
	}
}

// FailLocal marks an optimistic message as failed.
func (s *Store) FailLocal(cid, tmpID string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	list := s.messages[cid]
	for i := range list {
		if list[i].Local && list[i].TmpID == tmpID {
			list[i].State = StateFailed
		}
	}
}

func (s *Store) RemoveMessage(cid, id string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	list := s.messages[cid]
	out := list[:0]
	for _, m := range list {
		if m.ID != id {
			out = append(out, m)
		}
	}
	s.messages[cid] = out
}

// LatestIncomingID is the newest message from someone else (used for mark-as-read).
func (s *Store) LatestIncomingID(cid string) string {
	s.mu.Lock()
	defer s.mu.Unlock()
	list := s.messages[cid]
	for i := len(list) - 1; i >= 0; i-- {
		if !list[i].FromMe && !list[i].Local {
			return list[i].ID
		}
	}
	return ""
}

// ReceiveResult tells the caller what to refresh and whether to alert.
type ReceiveResult struct {
	MessagesChanged bool
	ConvChanged     bool
	FetchConv       bool   // conversation unknown: fetch it
	MarkRead        string // message id to mark read (the chat is open and focused)
	Alert           *Alert
}

// Receive applies a message from the phone. Logic mirrors the Mac app's AppModel.receive: an update to an
// older message (reaction, status change) must not move the conversation or alert, and each message alerts once.
func (s *Store) Receive(m Message, isOld bool, now time.Time) ReceiveResult {
	s.mu.Lock()
	defer s.mu.Unlock()
	var r ReceiveResult
	cid := m.ConversationID
	conv, known := s.convs[cid]
	list, tracked := s.messages[cid]
	isUpdate := false
	for i := range list {
		if list[i].ID == m.ID || m.Confirms(list[i]) {
			list[i] = merged(list[i], m)
			isUpdate = true
			break
		}
	}
	if !isUpdate && tracked {
		list = append(list, m)
	}
	if tracked {
		s.messages[cid] = normalize(list)
		r.MessagesChanged = true
	}

	isLatest := !known || m.Timestamp >= conv.Timestamp-1000
	if known {
		if isLatest && !m.Tombstone && !(m.Text == "" && len(m.Media) == 0) {
			conv.Preview = m.Summary()
			conv.Timestamp = maxI(conv.Timestamp, m.Timestamp)
			r.ConvChanged = true
		}
	} else {
		r.FetchConv = true
	}

	if m.FromMe || m.Tombstone || isOld || isUpdate || !isLatest {
		s.storeConv(known, conv)
		return r
	}
	if s.notified[m.ID] {
		s.storeConv(known, conv)
		return r
	}
	s.notified[m.ID] = true
	s.notifiedOrder = append(s.notifiedOrder, m.ID)
	if len(s.notifiedOrder) > 1000 {
		delete(s.notified, s.notifiedOrder[0])
		s.notifiedOrder = s.notifiedOrder[1:]
	}
	if now.Sub(time.UnixMilli(m.Timestamp)) > 24*time.Hour {
		s.storeConv(known, conv)
		return r
	}
	if s.isViewing(cid) {
		r.MarkRead = m.ID
		s.storeConv(known, conv)
		return r
	}
	if known {
		conv.Unread = true
		r.ConvChanged = true
	}
	s.storeConv(known, conv)
	r.Alert = &Alert{
		ConversationID:   cid,
		ConversationName: conv.Name,
		SenderName:       m.SenderName,
		Text:             m.Summary(),
		IsGroup:          conv.IsGroup,
		Timestamp:        time.UnixMilli(m.Timestamp),
	}
	return r
}

func (s *Store) storeConv(known bool, c Conversation) {
	if known {
		s.convs[c.ID] = c
	}
}

func merged(old, n Message) Message {
	if n.FromMe && n.State != StateFailed && old.State != StateFailed && StateRank(old.State) > StateRank(n.State) {
		n.State = old.State
	}
	return n
}

func mergeInto(list []Message, m Message) []Message {
	for i := range list {
		if list[i].ID == m.ID || m.Confirms(list[i]) {
			list[i] = merged(list[i], m)
			return list
		}
	}
	return append(list, m)
}

// normalize dedupes by id and sorts oldest first.
func normalize(list []Message) []Message {
	seen := map[string]bool{}
	out := list[:0]
	for _, m := range list {
		if seen[m.ID] {
			continue
		}
		seen[m.ID] = true
		out = append(out, m)
	}
	sort.SliceStable(out, func(i, j int) bool { return out[i].Timestamp < out[j].Timestamp })
	return out
}

func maxI(a, b int64) int64 {
	if a > b {
		return a
	}
	return b
}

// Package model converts libgm protobufs into plain view-model structs for the frontend and holds the pure,
// unit-tested logic (merging, delivery state, notification planning). Nothing here does network I/O.
package model

import (
	"encoding/base64"
	"fmt"
	"strconv"
	"strings"
	"time"

	"go.mau.fi/mautrix-gmessages/pkg/libgm"
	"go.mau.fi/mautrix-gmessages/pkg/libgm/gmproto"
)

// Delivery states, sent to the frontend as strings.
const (
	StateNone      = ""
	StateSending   = "sending"
	StateSent      = "sent"
	StateDelivered = "delivered"
	StateRead      = "read"
	StateFailed    = "failed"
)

// StateRank orders delivery states so status only moves forward (a late echo must not turn
// "Delivered" back into "Sending…").
func StateRank(s string) int {
	switch s {
	case StateSending:
		return 1
	case StateSent:
		return 2
	case StateDelivered:
		return 3
	case StateRead:
		return 4
	}
	return 0
}

func isTombstone(s int) bool { return s >= 200 && s < 300 }
func isFailed(s int) bool {
	switch s {
	case 8, 9, 13, 17, 18, 19, 21, 22, 24, 27:
		return true
	}
	return false
}
func isSending(s int) bool {
	switch s {
	case 3, 4, 5, 6, 7, 10, 20:
		return true
	}
	return false
}

type Media struct {
	ID       string `json:"id"`
	Key      string `json:"key"` // base64 decryption key
	Mime     string `json:"mime"`
	Name     string `json:"name"`
	ThumbID  string `json:"thumbId"`
	ThumbKey string `json:"thumbKey"`
	Width    int64  `json:"width"`
	Height   int64  `json:"height"`
	Size     int64  `json:"size"`
	Inline   []byte `json:"-"` // attachment bytes sent inside the message (no download)
}

// InlineMediaIDPrefix marks attachments whose bytes came inside the message.
const InlineMediaIDPrefix = "inline:"

func InlineMediaID(cid, msgID string, index int) string {
	return fmt.Sprintf("%s%s:%s:%d", InlineMediaIDPrefix, cid, msgID, index)
}

// MediaMime is the attachment's MIME type: the declared one, else derived from the format enum (as the bridge does).
func MediaMime(mc *gmproto.MediaContent) string {
	if m := strings.TrimSpace(mc.GetMimeType()); m != "" {
		return m
	}
	if mt, ok := libgm.FormatToMediaType[mc.GetFormat()]; ok && mt.Format != "" {
		return mt.Format
	}
	switch mc.GetFormat() {
	case gmproto.MediaFormats_IMAGE_UNSPECIFIED:
		return "image/jpeg"
	case gmproto.MediaFormats_VIDEO_UNSPECIFIED:
		return "video/mp4"
	case gmproto.MediaFormats_AUDIO_UNSPECIFIED:
		return "audio/mp4"
	}
	return ""
}

type Reaction struct {
	Emoji string `json:"emoji"`
	Count int    `json:"count"`
	ByMe  bool   `json:"byMe"`
}

type Message struct {
	ID              string     `json:"id"`
	TmpID           string     `json:"tmpId"`
	ConversationID  string     `json:"conversationId"`
	Text            string     `json:"text"`
	Subject         string     `json:"subject"`
	FromMe          bool       `json:"fromMe"`
	SenderName      string     `json:"senderName"`
	ParticipantID   string     `json:"participantId"`
	Timestamp       int64      `json:"timestamp"` // unix milliseconds
	State           string     `json:"state"`
	Media           []Media    `json:"media"`
	Reactions       []Reaction `json:"reactions"`
	ReplyToID       string     `json:"replyToId"`
	SenderIsContact bool       `json:"senderIsContact"`
	Tombstone       bool       `json:"tombstone"`
	Local           bool       `json:"local"`
	PendingMedia    int        `json:"pendingMedia"`
}

type Conversation struct {
	ID             string   `json:"id"`
	Name           string   `json:"name"`
	Preview        string   `json:"preview"`
	Timestamp      int64    `json:"timestamp"` // unix milliseconds
	Unread         bool     `json:"unread"`
	IsGroup        bool     `json:"isGroup"`
	Pinned         bool     `json:"pinned"`
	Archived       bool     `json:"archived"`
	ReadOnly       bool     `json:"readOnly"`
	Color          string   `json:"color"`
	AvatarIDs      []string `json:"avatarIds"`
	MyID           string   `json:"myId"`
	GroupAvatarURL string   `json:"-"`
	LatestMsgID    string   `json:"-"`
	HasGroupAvatar bool     `json:"hasGroupAvatar"`
	IsRCS          bool     `json:"isRcs"`
	Participants   []string `json:"participants"` // display names of others, for group headers
	// ContactIDs are the participant ids that are saved contacts on the phone (link previews default to these).
	ContactIDs []string `json:"contactIds"`
	// Numbers of the other participants (used when deleting a 1:1 chat, like the bridge).
	Numbers []string `json:"-"`
	// Hidden: deleted, spam, blocked or trashed on the phone; the store drops these.
	Hidden bool `json:"-"`
}

func micros(ts int64) int64 { return ts / 1000 }

// ConvertMessage maps a libgm message. myID is the conversation's default outgoing participant id.
func ConvertMessage(m *gmproto.Message, myID string) Message {
	status := int(m.GetMessageStatus().GetStatus())
	sender := m.GetSenderParticipant()
	vm := Message{
		ID:             m.GetMessageID(),
		TmpID:          m.GetTmpID(),
		ConversationID: m.GetConversationID(),
		ParticipantID:  m.GetParticipantID(),
		Timestamp:      micros(m.GetTimestamp()),
		Subject:        m.GetSubject(),
		Tombstone:      isTombstone(status),
		Media:          []Media{},
		Reactions:      []Reaction{},
	}
	if vm.ID == "" {
		vm.ID = vm.TmpID
	}
	vm.FromMe = (status >= 1 && status < 100) || sender.GetIsMe() || (myID != "" && vm.ParticipantID == myID)
	vm.SenderIsContact = sender.GetContactID() != ""
	vm.SenderName = sender.GetFullName()
	if vm.SenderName == "" {
		vm.SenderName = sender.GetFirstName()
	}
	if vm.SenderName == "" {
		vm.SenderName = sender.GetFormattedNumber()
	}
	var texts []string
	for _, info := range m.GetMessageInfo() {
		if c := info.GetMessageContent(); c != nil && c.GetContent() != "" {
			texts = append(texts, c.GetContent())
		} else if mc := info.GetMediaContent(); mc != nil {
			md := Media{
				ID:       mc.GetMediaID(),
				Key:      base64.StdEncoding.EncodeToString(mc.GetDecryptionKey()),
				Mime:     MediaMime(mc),
				Name:     mc.GetMediaName(),
				ThumbID:  mc.GetThumbnailMediaID(),
				ThumbKey: base64.StdEncoding.EncodeToString(mc.GetThumbnailDecryptionKey()),
				Width:    mc.GetDimensions().GetWidth(),
				Height:   mc.GetDimensions().GetHeight(),
				Size:     mc.GetSize(),
			}
			// Like mautrix-gmessages: fall back to the thumbnail, then to data sent inline in the message.
			if md.ID == "" && md.ThumbID != "" {
				md.ID, md.Key = md.ThumbID, md.ThumbKey
			}
			if md.ID == "" && len(mc.GetMediaData()) > 0 {
				md.ID, md.Key = InlineMediaID(vm.ConversationID, vm.ID, len(vm.Media)), ""
				md.Inline = mc.GetMediaData()
			}
			vm.Media = append(vm.Media, md)
		}
	}
	vm.Text = strings.Join(texts, "\n")
	if vm.FromMe {
		switch {
		case isFailed(status):
			vm.State = StateFailed
		case status == 11:
			vm.State = StateRead
		case status == 2:
			vm.State = StateDelivered
		case isSending(status):
			vm.State = StateSending
		default:
			vm.State = StateSent
		}
	}
	for _, r := range m.GetReactions() {
		e := r.GetData().GetUnicode()
		ids := r.GetParticipantIDs()
		if e == "" || len(ids) == 0 {
			continue
		}
		byMe := false
		for _, id := range ids {
			if myID != "" && id == myID {
				byMe = true
			}
		}
		vm.Reactions = append(vm.Reactions, Reaction{Emoji: e, Count: len(ids), ByMe: byMe})
	}
	if rm := m.GetReplyMessage(); rm != nil {
		vm.ReplyToID = rm.GetMessageID()
	}
	return vm
}

// NewLocalMessage is the optimistic copy shown while a send is in flight.
func NewLocalMessage(text, tmpID, convID, replyTo string, pendingMedia int, now time.Time) Message {
	return Message{
		ID: tmpID, TmpID: tmpID, ConversationID: convID, Text: text, FromMe: true,
		Timestamp: now.UnixMilli(), State: StateSending, Media: []Media{}, Reactions: []Reaction{},
		ReplyToID: replyTo, Local: true, PendingMedia: pendingMedia,
	}
}

// Summary is the one-line description used in the sidebar and notifications.
func (m Message) Summary() string {
	if m.Text != "" {
		return m.Text
	}
	n := len(m.Media)
	if m.PendingMedia > n {
		n = m.PendingMedia
	}
	if n > 1 {
		return strconv.Itoa(n) + " attachments"
	}
	if len(m.Media) == 0 {
		return "Attachment"
	}
	mt := m.Media[0].Mime
	switch {
	case strings.HasPrefix(mt, "image/"):
		return "📷 Photo"
	case strings.HasPrefix(mt, "video/"):
		return "🎥 Video"
	case strings.HasPrefix(mt, "audio/"):
		return "🎤 Audio message"
	}
	if m.Media[0].Name != "" {
		return "📎 " + m.Media[0].Name
	}
	return "📎 Attachment"
}

// Confirms reports whether m (from the phone) is the echo of the local optimistic message.
func (m Message) Confirms(local Message) bool {
	if !local.Local || !m.FromMe || local.ConversationID != m.ConversationID {
		return false
	}
	if m.TmpID != "" && m.TmpID == local.TmpID {
		return true
	}
	want := len(local.Media)
	if local.PendingMedia > want {
		want = local.PendingMedia
	}
	return m.Text == local.Text && len(m.Media) == want
}

func ConvertConversation(c *gmproto.Conversation) Conversation {
	vm := Conversation{
		ID:             c.GetConversationID(),
		Name:           c.GetName(),
		Preview:        c.GetLatestMessage().GetDisplayContent(),
		Timestamp:      micros(c.GetLastMessageTimestamp()),
		Unread:         c.GetUnread(),
		IsGroup:        c.GetIsGroupChat(),
		Pinned:         c.GetPinned(),
		ReadOnly:       c.GetReadOnly(),
		Color:          c.GetAvatarHexColor(),
		MyID:           c.GetDefaultOutgoingID(),
		GroupAvatarURL: c.GetGroupAvatarURL(),
		LatestMsgID:    c.GetLatestMessageID(),
		IsRCS:          c.GetType() == gmproto.ConversationType_RCS,
		AvatarIDs:      []string{},
		Participants:   []string{},
		ContactIDs:     []string{},
	}
	vm.HasGroupAvatar = vm.GroupAvatarURL != ""
	st := c.GetStatus()
	vm.Archived = st == gmproto.ConversationStatus_ARCHIVED || st == gmproto.ConversationStatus_KEEP_ARCHIVED
	switch st {
	case gmproto.ConversationStatus_DELETED, gmproto.ConversationStatus_SPAM_FOLDER, gmproto.ConversationStatus_BLOCKED_FOLDER,
		gmproto.ConversationStatus_TRASH_FOLDER:
		vm.Hidden = true
	}
	others := map[string]bool{}
	for _, id := range c.GetOtherParticipants() {
		others[id] = true
	}
	for _, p := range c.GetParticipants() {
		id := p.GetID().GetParticipantID()
		if !p.GetIsMe() && p.GetContactID() != "" && id != "" {
			vm.ContactIDs = append(vm.ContactIDs, id)
		}
		if p.GetIsMe() || (len(others) > 0 && !others[id]) {
			continue
		}
		vm.AvatarIDs = append(vm.AvatarIDs, id)
		if n := p.GetID().GetNumber(); n != "" {
			vm.Numbers = append(vm.Numbers, n)
		}
		name := p.GetFullName()
		if name == "" {
			name = p.GetFormattedNumber()
		}
		if name != "" {
			vm.Participants = append(vm.Participants, name)
		}
	}
	return vm
}

package model

import (
	"testing"
	"time"

	"go.mau.fi/mautrix-gmessages/pkg/libgm/gmproto"
)

var now = time.Date(2026, 11, 9, 12, 0, 0, 0, time.UTC)

func alert(cid, name string, ago time.Duration) Alert {
	return Alert{ConversationID: cid, ConversationName: name, SenderName: name, Text: "hi " + name, Timestamp: now.Add(-ago)}
}

func TestPlanGroupsPerConversation(t *testing.T) {
	p := Plan([]Alert{alert("a", "Ann", 3*time.Second), alert("a", "Ann", 2*time.Second), alert("b", "Bob", time.Second)}, false, now, true)
	if len(p) != 2 {
		t.Fatalf("want 2 notifications, got %d", len(p))
	}
	if p[0].ID != "conv.a" || p[0].Subtitle != "2 new messages" || p[1].ID != "conv.b" {
		t.Fatalf("unexpected plan %+v", p)
	}
}

func TestPlanSummarisesDuringCatchUp(t *testing.T) {
	var alerts []Alert
	for _, n := range []string{"A", "B", "C", "D", "E"} {
		alerts = append(alerts, alert(n, n, time.Second))
	}
	p := Plan(alerts, true, now, true)
	if len(p) != 1 || p[0].ID != SummaryID || p[0].Title != "5 new messages" {
		t.Fatalf("want one summary, got %+v", p)
	}
	// Not catching up and fresh: one each.
	if got := len(Plan(alerts, false, now, true)); got != 5 {
		t.Fatalf("want 5, got %d", got)
	}
	// Stale alerts force a summary even outside catch-up.
	alerts[0].Timestamp = now.Add(-StaleAfter - time.Second)
	if got := Plan(alerts, false, now, true); len(got) != 1 {
		t.Fatalf("stale alerts should summarise, got %d", len(got))
	}
}

func TestPlanHidesPreviews(t *testing.T) {
	p := Plan([]Alert{alert("a", "Ann", time.Second)}, false, now, false)
	if p[0].Body != "New message" {
		t.Fatalf("preview leaked: %q", p[0].Body)
	}
}

func msg(id, cid string, ts time.Time, fromMe bool) Message {
	m := Message{ID: id, ConversationID: cid, Text: "x", Timestamp: ts.UnixMilli(), FromMe: fromMe, SenderName: "Ann"}
	if fromMe {
		m.State = StateSent
	}
	return m
}

func TestReceiveAlertsOnce(t *testing.T) {
	s := NewStore()
	s.UpsertConversation(Conversation{ID: "c", Name: "Ann", Timestamp: now.Add(-time.Minute).UnixMilli()})
	r := s.Receive(msg("m1", "c", now, false), false, now)
	if r.Alert == nil {
		t.Fatal("expected alert")
	}
	if r2 := s.Receive(msg("m1", "c", now, false), false, now); r2.Alert != nil {
		t.Fatal("duplicate must not alert")
	}
	if c, _ := s.Conversation("c"); !c.Unread {
		t.Fatal("conversation should be unread")
	}
}

func TestReceiveSkipsOldAndViewing(t *testing.T) {
	s := NewStore()
	s.UpsertConversation(Conversation{ID: "c", Timestamp: now.Add(-time.Minute).UnixMilli()})
	if r := s.Receive(msg("old", "c", now, false), true, now); r.Alert != nil {
		t.Fatal("isOld must not alert")
	}
	// Update to an older message (e.g. reaction) must not alert or move the conversation.
	s.UpsertConversation(Conversation{ID: "d", Preview: "latest", Timestamp: now.UnixMilli()})
	if r := s.Receive(msg("older", "d", now.Add(-time.Hour), false), false, now); r.Alert != nil {
		t.Fatal("older message must not alert")
	}
	if c, _ := s.Conversation("d"); c.Preview != "latest" {
		t.Fatal("older message moved the preview")
	}
	s.SetViewing("c", true)
	r := s.Receive(msg("new", "c", now.Add(time.Second), false), false, now)
	if r.Alert != nil || r.MarkRead != "new" {
		t.Fatalf("viewing chat should mark read, not alert: %+v", r)
	}
}

func TestOptimisticEchoAndStateOnlyMovesForward(t *testing.T) {
	s := NewStore()
	s.AddHistory("c", nil)
	local := NewLocalMessage("hello", "tmp_1", "c", "", 0, now)
	s.AddLocal(local)
	delivered := msg("real1", "c", now, true)
	delivered.Text, delivered.TmpID, delivered.State = "hello", "tmp_1", StateDelivered
	s.Receive(delivered, false, now)
	late := delivered
	late.State = StateSending
	s.Receive(late, false, now)
	list := s.Messages("c")
	if len(list) != 1 {
		t.Fatalf("echo should replace local copy, have %d", len(list))
	}
	if list[0].ID != "real1" || list[0].State != StateDelivered || list[0].Local {
		t.Fatalf("bad merge: %+v", list[0])
	}
}

func TestConvertMessage(t *testing.T) {
	sub := "subj"
	m := &gmproto.Message{
		MessageID: "1", ConversationID: "c", ParticipantID: "me", Timestamp: now.UnixMicro(), Subject: &sub,
		MessageStatus: &gmproto.MessageStatus{Status: gmproto.MessageStatusType_OUTGOING_DISPLAYED},
		MessageInfo: []*gmproto.MessageInfo{
			{Data: &gmproto.MessageInfo_MessageContent{MessageContent: &gmproto.MessageContent{Content: "hi"}}},
			{Data: &gmproto.MessageInfo_MediaContent{MediaContent: &gmproto.MediaContent{MediaID: "m", MimeType: "image/png", DecryptionKey: []byte{1}}}},
		},
		Reactions: []*gmproto.ReactionEntry{{Data: &gmproto.ReactionData{Unicode: "👍"}, ParticipantIDs: []string{"me", "x"}}},
	}
	vm := ConvertMessage(m, "me")
	if !vm.FromMe || vm.State != StateRead || vm.Text != "hi" || len(vm.Media) != 1 || vm.Media[0].Key != "AQ==" {
		t.Fatalf("bad convert: %+v", vm)
	}
	if vm.Timestamp != now.UnixMilli() || vm.Subject != "subj" {
		t.Fatalf("bad timestamp/subject: %+v", vm)
	}
	if len(vm.Reactions) != 1 || vm.Reactions[0].Count != 2 || !vm.Reactions[0].ByMe {
		t.Fatalf("bad reactions: %+v", vm.Reactions)
	}
	// Nil-safe on empty input (network data).
	_ = ConvertMessage(&gmproto.Message{}, "")
	_ = ConvertConversation(&gmproto.Conversation{})
}

func TestConversationsSortedAndDeduped(t *testing.T) {
	s := NewStore()
	s.UpsertConversation(Conversation{ID: "a", Timestamp: 1})
	s.UpsertConversation(Conversation{ID: "b", Timestamp: 2})
	s.UpsertConversation(Conversation{ID: "p", Timestamp: 0, Pinned: true})
	s.UpsertConversation(Conversation{ID: "p", Timestamp: 0, Pinned: true}) // pinned chats arrive twice
	list := s.Conversations()
	if len(list) != 3 || list[0].ID != "p" || list[1].ID != "b" {
		t.Fatalf("bad order: %+v", list)
	}
}

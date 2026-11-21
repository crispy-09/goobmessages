package model

import (
	"strings"
	"testing"
	"time"
)

func TestHiddenConversationsAreRemoved(t *testing.T) {
	s := NewStore()
	s.UpsertConversation(Conversation{ID: "c1", Timestamp: 5})
	s.AddHistory("c1", []Message{{ID: "m1", ConversationID: "c1"}})
	s.UpsertConversation(Conversation{ID: "c1", Hidden: true})
	if _, ok := s.Conversation("c1"); ok || len(s.Messages("c1")) != 0 {
		t.Fatal("deleted conversation still stored")
	}
	s.UpsertConversation(Conversation{ID: "c2"})
	if !s.SetArchived("c2", true) {
		t.Fatal("SetArchived")
	}
	if c, _ := s.Conversation("c2"); !c.Archived {
		t.Fatal("not archived")
	}
	if s.SetArchived("missing", true) {
		t.Fatal("archived a missing conversation")
	}
}

func TestLocalPinsOverridePhone(t *testing.T) {
	s := NewStore()
	s.UpsertConversation(Conversation{ID: "old", Timestamp: 1})
	s.UpsertConversation(Conversation{ID: "new", Timestamp: 9})
	s.UpsertConversation(Conversation{ID: "phonepin", Timestamp: 5, Pinned: true})
	s.SetPins(map[string]bool{"old": true, "phonepin": false})
	got := s.Conversations()
	if got[0].ID != "old" || !got[0].Pinned {
		t.Fatalf("locally pinned chat not first: %+v", got)
	}
	if got[1].ID != "new" || got[2].ID != "phonepin" || got[2].Pinned {
		t.Fatalf("unpin override not applied: %+v", got)
	}
}

func TestSyncNewestDropsDeletedAndKeepsNewer(t *testing.T) {
	s := NewStore()
	m := func(id string, ts int64) Message { return Message{ID: id, ConversationID: "c", Timestamp: ts} }
	s.AddHistory("c", []Message{m("1", 10), m("2", 20), m("3", 30), m("4", 40)})
	s.Receive(m("9", 90), false, time.UnixMilli(90)) // arrived while the page was being fetched
	// The phone's newest page covers 20..50: "3" was deleted on the phone, "5" is new.
	s.SyncNewest("c", []Message{m("2", 20), m("4", 40), m("5", 50)}, false)
	if got := ids(s.Messages("c")); got != "1,2,4,5,9" {
		t.Fatalf("got %s", got)
	}
	// A complete page (the whole conversation) also removes older messages it doesn't contain.
	s.SyncNewest("c", []Message{m("4", 40), m("5", 50)}, true)
	if got := ids(s.Messages("c")); got != "4,5,9" {
		t.Fatalf("complete: got %s", got)
	}
}

func TestReplaceHistoryKeepsLocal(t *testing.T) {
	s := NewStore()
	s.AddHistory("c", []Message{{ID: "1", ConversationID: "c", Timestamp: 1}})
	s.AddLocal(Message{ID: "tmp", TmpID: "tmp", ConversationID: "c", Local: true, Timestamp: 5})
	s.ReplaceHistory("c", []Message{{ID: "7", ConversationID: "c", Timestamp: 7}})
	if got := ids(s.Messages("c")); got != "tmp,7" {
		t.Fatalf("got %s", got)
	}
	if s.NewestTimestamp("c") != 7 {
		t.Fatal("NewestTimestamp should ignore local messages")
	}
}

func ids(list []Message) string {
	var out []string
	for _, m := range list {
		out = append(out, m.ID)
	}
	return strings.Join(out, ",")
}

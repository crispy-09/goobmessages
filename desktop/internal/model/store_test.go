package model

import "testing"

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

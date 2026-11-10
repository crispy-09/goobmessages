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

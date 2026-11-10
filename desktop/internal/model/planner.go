package model

import (
	"sort"
	"strconv"
	"strings"
	"time"
)

// Alert is one incoming message that may deserve a notification.
type Alert struct {
	ConversationID   string
	ConversationName string
	SenderName       string
	Text             string
	IsGroup          bool
	Timestamp        time.Time
}

// Planned is a notification ready to post. ID is per conversation so a newer alert replaces the older one
// instead of stacking a banner per message.
type Planned struct {
	ID             string
	Title          string
	Subtitle       string
	Body           string
	ConversationID string // empty for the summary notification
}

const (
	StaleAfter                    = 120 * time.Second
	MaxConversationsBeforeSummary = 3
	SummaryID                     = "goob.summary"
)

func NotificationID(convID string) string { return "conv." + convID }

// Plan turns a batch of alerts into the fewest useful notifications (port of the Mac NotificationPlanner):
// grouped per conversation; during catch-up (launch, wake, reconnect) or when any alert is stale, many
// conversations collapse into one summary.
func Plan(alerts []Alert, catchUp bool, now time.Time, previews bool) []Planned {
	if len(alerts) == 0 {
		return nil
	}
	sorted := append([]Alert(nil), alerts...)
	sort.SliceStable(sorted, func(i, j int) bool { return sorted[i].Timestamp.Before(sorted[j].Timestamp) })
	var order []string // conversations, oldest activity first
	groups := map[string][]Alert{}
	summarize := catchUp
	for _, a := range sorted {
		if _, ok := groups[a.ConversationID]; ok {
			order = remove(order, a.ConversationID)
		}
		order = append(order, a.ConversationID)
		groups[a.ConversationID] = append(groups[a.ConversationID], a)
		if now.Sub(a.Timestamp) > StaleAfter {
			summarize = true
		}
	}

	if summarize && len(order) > MaxConversationsBeforeSummary {
		var names []string
		for i := len(order) - 1; i >= 0; i-- {
			g := groups[order[i]]
			names = append(names, displayName(g[len(g)-1]))
		}
		body := "From " + strconv.Itoa(len(names)) + " conversations"
		if previews {
			shown := strings.Join(names[:min(3, len(names))], ", ")
			body = "From " + shown
			if len(names) > 3 {
				body += " and " + strconv.Itoa(len(names)-3) + " more"
			}
		}
		return []Planned{{ID: SummaryID, Title: strconv.Itoa(len(alerts)) + " new messages", Body: body}}
	}

	out := make([]Planned, 0, len(order))
	for _, cid := range order {
		items := groups[cid]
		last := items[len(items)-1]
		n := len(items)
		subtitle := ""
		if last.IsGroup {
			subtitle = last.SenderName
		}
		var body string
		if !previews {
			body = "New message"
			if n > 1 {
				body = strconv.Itoa(n) + " new messages"
			}
		} else {
			body = last.Text
			if n > 1 {
				tag := strconv.Itoa(n) + " new messages"
				if subtitle == "" {
					subtitle = tag
				} else {
					subtitle = tag + " · " + subtitle
				}
			}
		}
		out = append(out, Planned{ID: NotificationID(cid), Title: displayName(last), Subtitle: subtitle, Body: body, ConversationID: cid})
	}
	return out
}

func displayName(a Alert) string {
	if a.ConversationName != "" {
		return a.ConversationName
	}
	if a.SenderName != "" {
		return a.SenderName
	}
	return "Someone"
}

func remove(list []string, v string) []string {
	out := list[:0]
	for _, x := range list {
		if x != v {
			out = append(out, x)
		}
	}
	return out
}

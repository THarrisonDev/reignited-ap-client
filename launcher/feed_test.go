// Author: Tim Harrison
// Created: 2026-09-26
// Updated: 2026-10-11

package main

import (
	"context"
	"encoding/json"
	"fmt"
	"html/template"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
)

const (
	roomInfoJS    = `[{"cmd":"RoomInfo","games":["Jigsaw","Spyro Reignited Trilogy"]}]`
	dataPackageJS = `[{"cmd":"DataPackage","data":{"games":{
		"Jigsaw":{"item_name_to_id":{"1 Puzzle Piece":500},"location_name_to_id":{"Merge 25 times":900}},
		"Spyro Reignited Trilogy":{"item_name_to_id":{"Dragon":10,"Terrace Village Key":11},
			"location_name_to_id":{"Artisans: Free Nestor":100,"Artisans: Free Argus":101}}}}}]`
	connectedJS = `[{"cmd":"Connected","slot":2,
		"players":[{"team":0,"slot":1,"alias":"SpeedyLink","name":"SpeedyLink"},{"team":0,"slot":2,"alias":"SRTPlayer","name":"SRTPlayer"}],
		"slot_info":{"1":{"name":"SpeedyLink","game":"Jigsaw","type":1},"2":{"name":"SRTPlayer","game":"Spyro Reignited Trilogy","type":1}},
		"checked_locations":[100],"missing_locations":[101,102,103]}]`
)

func itemSendJS(receiving, finder int, item, loc int64, flags int) string {
	return fmt.Sprintf(`[{"cmd":"PrintJSON","type":"ItemSend","data":[{"text":"..."}],"receiving":%d,`+
		`"item":{"item":%d,"location":%d,"player":%d,"flags":%d,"class":"NetworkItem"}}]`,
		receiving, item, loc, finder, flags)
}

func testSession(t *testing.T) (*Feed, *apSession, *[]map[string]any) {
	t.Helper()
	f := NewFeed()
	var sent []map[string]any
	s := newAPSession(f, feedConn{Host: "127.0.0.1:38281", Slot: "SRTPlayer"}, func(cmds ...any) error {
		b, err := json.Marshal(cmds)
		if err != nil {
			return err
		}
		var out []map[string]any
		if err := json.Unmarshal(b, &out); err != nil {
			return err
		}
		sent = append(sent, out...)
		return nil
	})
	return f, s, &sent
}

func mustHandle(t *testing.T, s *apSession, js string) {
	t.Helper()
	if err := s.handle([]byte(js)); err != nil {
		t.Fatalf("handle: %v", err)
	}
}

func TestFeedConnectsAsTextOnly(t *testing.T) {
	_, s, sent := testSession(t)
	mustHandle(t, s, roomInfoJS)
	if len(*sent) != 2 {
		t.Fatalf("want GetDataPackage + Connect, got %v", *sent)
	}
	pkg, conn := (*sent)[0], (*sent)[1]
	if pkg["cmd"] != "GetDataPackage" || len(pkg["games"].([]any)) != 2 {
		t.Errorf("GetDataPackage = %v", pkg)
	}
	if conn["cmd"] != "Connect" || conn["name"] != "SRTPlayer" || conn["game"] != "" ||
		conn["items_handling"] != float64(0) || !reflect.DeepEqual(conn["tags"], []any{"TextOnly"}) {
		t.Errorf("Connect = %v", conn)
	}
}

func TestFeedClassifiesItemMovements(t *testing.T) {
	f, s, _ := testSession(t)
	mustHandle(t, s, roomInfoJS)
	mustHandle(t, s, dataPackageJS)
	mustHandle(t, s, connectedJS)

	v := f.View()
	if !v.Connected || v.Checked != 1 || v.Total != 4 {
		t.Fatalf("after Connected: %+v", v)
	}

	mustHandle(t, s, itemSendJS(1, 2, 500, 101, 1)) // our location, their item
	mustHandle(t, s, itemSendJS(2, 1, 11, 900, 1))  // their location, our item
	mustHandle(t, s, itemSendJS(2, 2, 10, 100, 0))  // our location, our item
	mustHandle(t, s, itemSendJS(1, 1, 500, 900, 0)) // not ours: ignored

	got := f.View().Events
	if len(got) != 3 {
		t.Fatalf("want 3 events, got %+v", got)
	}
	want := []FeedEvent{
		{Kind: "found", Item: "Dragon", Location: "Artisans: Free Nestor"},
		{Kind: "received", Item: "Terrace Village Key", Other: "SpeedyLink", Location: "Merge 25 times", Progression: true},
		{Kind: "sent", Item: "1 Puzzle Piece", Other: "SpeedyLink", Location: "Artisans: Free Argus", Progression: true},
	}
	for i := range want {
		got[i].Time = time.Time{}
		if got[i] != want[i] {
			t.Errorf("event %d = %+v, want %+v", i, got[i], want[i])
		}
	}

	mustHandle(t, s, `[{"cmd":"RoomUpdate","checked_locations":[101]}]`)
	mustHandle(t, s, `[{"cmd":"RoomUpdate","checked_locations":[101]}]`)
	if v := f.View(); v.Checked != 2 || v.Total != 4 {
		t.Errorf("after RoomUpdate: checked %d/%d, want 2/4", v.Checked, v.Total)
	}
}

func TestFeedUnknownIDsAndServerGrants(t *testing.T) {
	f, s, _ := testSession(t)
	mustHandle(t, s, connectedJS)
	mustHandle(t, s, itemSendJS(2, 0, 77, -2, 0))
	got := f.View().Events
	if len(got) != 1 || got[0].Item != "Item #77" || got[0].Other != "Archipelago" || got[0].Location != "" {
		t.Errorf("server grant without data package = %+v", got)
	}
}

func TestFeedRefusedExplainsWhy(t *testing.T) {
	_, s, _ := testSession(t)
	err := s.handle([]byte(`[{"cmd":"ConnectionRefused","errors":["InvalidSlot"]}]`))
	if err == nil || !strings.Contains(err.Error(), `no slot named "SRTPlayer"`) {
		t.Errorf("refused error = %v", err)
	}
}

func TestFeedKeepsNewestEvents(t *testing.T) {
	f := NewFeed()
	for i := 0; i < feedMaxEvents+5; i++ {
		f.add(FeedEvent{Kind: "sent", Item: fmt.Sprint(i)})
	}
	v := f.View()
	if len(v.Events) != feedMaxEvents || v.Events[0].Item != fmt.Sprint(feedMaxEvents+4) {
		t.Errorf("len %d, newest %q", len(v.Events), v.Events[0].Item)
	}
}

func TestFeedURLs(t *testing.T) {
	cases := map[string][]string{
		"127.0.0.1:38281":              {"wss://127.0.0.1:38281", "ws://127.0.0.1:38281"},
		"archipelago.gg":               {"wss://archipelago.gg:38281", "ws://archipelago.gg:38281"},
		"ws://localhost:1234":          {"ws://localhost:1234"},
		"https://archipelago.gg:5000/": {"wss://archipelago.gg:5000"},
		"":                             {"wss://127.0.0.1:38281", "ws://127.0.0.1:38281"},
	}
	for in, want := range cases {
		if got := feedURLs(in); !reflect.DeepEqual(got, want) {
			t.Errorf("feedURLs(%q) = %v, want %v", in, got, want)
		}
	}
}

// End to end over a real websocket: dial, TextOnly handshake, an ItemSend.
func TestFeedRunAgainstServer(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		c, err := websocket.Accept(w, r, nil)
		if err != nil {
			return
		}
		defer func() { _ = c.CloseNow() }()
		ctx := context.Background()
		_ = c.Write(ctx, websocket.MessageText, []byte(roomInfoJS))
		_, b, err := c.Read(ctx)
		if err != nil || !strings.Contains(string(b), `"Connect"`) {
			return
		}
		for _, js := range []string{dataPackageJS, connectedJS, itemSendJS(1, 2, 500, 101, 1)} {
			_ = c.Write(ctx, websocket.MessageText, []byte(js))
		}
		for {
			if _, _, err := c.Read(ctx); err != nil {
				return
			}
		}
	}))
	defer srv.Close()

	f := NewFeed()
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	host := "ws://" + strings.TrimPrefix(srv.URL, "http://")
	go func() {
		f.Run(ctx, func() feedConn { return feedConn{Host: host, Slot: "SRTPlayer"} })
		close(done)
	}()

	deadline := time.Now().Add(5 * time.Second)
	for len(f.View().Events) == 0 && time.Now().Before(deadline) {
		time.Sleep(20 * time.Millisecond)
	}
	v := f.View()
	cancel()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("Run did not stop after cancel")
	}
	if !v.Connected || len(v.Events) != 1 || v.Events[0].Other != "SpeedyLink" {
		t.Fatalf("feed after run: %+v", v)
	}
}

func TestFeedFragmentEscapesNames(t *testing.T) {
	tmpl := template.Must(template.New("index").Parse(indexHTML))
	f := NewFeed()
	f.setStatus(true, "Connected as SRTPlayer.")
	f.setChecks(3, 238)
	f.add(FeedEvent{Kind: "sent", Item: "<b>Hookshot</b>", Other: "Bob", Location: "Link's House"})
	s := &server{tmpl: tmpl, feed: f}

	rec := httptest.NewRecorder()
	s.handleFeed(rec, httptest.NewRequest("GET", "/feed", nil))
	body := rec.Body.String()
	for _, want := range []string{"&lt;b&gt;Hookshot&lt;/b&gt;", "Bob", "Connected as SRTPlayer.", "3 / 238"} {
		if !strings.Contains(body, want) {
			t.Errorf("feed fragment missing %q:\n%s", want, body)
		}
	}

	var page strings.Builder
	if err := tmpl.ExecuteTemplate(&page, "page", view{Feed: f.View()}); err != nil {
		t.Fatalf("page template: %v", err)
	}
	if !strings.Contains(page.String(), `hx-get="/feed"`) {
		t.Error("page does not poll /feed")
	}
}

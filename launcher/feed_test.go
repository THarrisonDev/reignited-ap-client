// Author: Tim Harrison
// Created: 2026-09-26
// Updated: 2026-11-11

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
			"location_name_to_id":{"Artisans: Free Nestor":100,"Artisans: Free Argus":101,
				"Artisans: Free Nevin":102,"Artisans: Free Lindar":103}}}}}]`
	connectedJS = `[{"cmd":"Connected","slot":2,
		"players":[{"team":0,"slot":1,"alias":"SpeedyLink","name":"SpeedyLink"},{"team":0,"slot":2,"alias":"SRTPlayer","name":"SRTPlayer"}],
		"slot_info":{"1":{"name":"SpeedyLink","game":"Jigsaw","type":1},"2":{"name":"SRTPlayer","game":"Spyro Reignited Trilogy","type":1}},
		"checked_locations":[100],"missing_locations":[101,102,103]}]`
	hintRoomInfoJS = `[{"cmd":"RoomInfo","games":["Spyro Reignited Trilogy"],` +
		`"hint_cost":10,"location_check_points":1}]`
	hintConnectedJS = `[{"cmd":"Connected","slot":2,"hint_points":30,
		"players":[{"team":0,"slot":1,"alias":"SpeedyLink","name":"SpeedyLink"},{"team":0,"slot":2,"alias":"SRTPlayer","name":"SRTPlayer"}],
		"slot_info":{"1":{"name":"SpeedyLink","game":"Jigsaw","type":1},"2":{"name":"SRTPlayer","game":"Spyro Reignited Trilogy","type":1}},
		"checked_locations":[100,101],"missing_locations":[102,103]}]`
	retrievedHintsJS = `[{"cmd":"Retrieved","keys":{"_read_hints_0_2":[
		{"receiving_player":2,"finding_player":2,"location":100,"item":10,"found":false,"entrance":"","item_flags":1,"status":30,"class":"Hint"},
		{"receiving_player":1,"finding_player":2,"location":101,"item":500,"found":true,"entrance":"","item_flags":0,"status":30,"class":"Hint"}]}}]`
	setReplyHintsJS = `[{"cmd":"SetReply","key":"_read_hints_0_2","value":[
		{"receiving_player":1,"finding_player":1,"location":900,"item":500,"found":true,"entrance":"","item_flags":0,"status":30,"class":"Hint"}]}]`
	commandResultJS = `[{"cmd":"PrintJSON","type":"CommandResult","data":[
		{"text":" You can't afford the hint. "},{"text":"You have 3 points and need at least 13."}]}]`
	hintItemsPackageJS = `[{"cmd":"DataPackage","data":{"games":{"Spyro Reignited Trilogy":{
		"item_name_to_id":{"Spyro 1: Terrace Village Key":1,"Spyro 2: Glimmer Key":2,
			"Spyro 3: Sunrise Spring Key":3,"Flat Spyro Mode":4},
		"location_name_to_id":{"Spyro 1: Artisans: Free Nestor":100}}}}}]`
	hintConnectedS1S2JS = `[{"cmd":"Connected","slot":2,"hint_points":5,
		"players":[{"team":0,"slot":2,"alias":"SRTPlayer","name":"SRTPlayer"}],
		"slot_info":{"2":{"name":"SRTPlayer","game":"Spyro Reignited Trilogy","type":1}},
		"slot_data":{"included_games":["spyro1","spyro2"],"required_games":["spyro1","spyro2"]},
		"checked_locations":[],"missing_locations":[100]}]`
	hintConnectedNoGamesJS = `[{"cmd":"Connected","slot":2,"hint_points":5,
		"players":[{"team":0,"slot":2,"alias":"SRTPlayer","name":"SRTPlayer"}],
		"slot_info":{"2":{"name":"SRTPlayer","game":"Spyro Reignited Trilogy","type":1}},
		"slot_data":{"other_option":true},
		"checked_locations":[],"missing_locations":[100]}]`
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

// stubSession builds a session on f whose outgoing commands land on the
// returned channel, so a test can watch the wire without a server.
func stubSession(f *Feed, cfg feedConn) (*apSession, <-chan map[string]any) {
	out := make(chan map[string]any, 16)
	s := newAPSession(f, cfg, func(cmds ...any) error {
		b, err := json.Marshal(cmds)
		if err != nil {
			return err
		}
		var got []map[string]any
		if err := json.Unmarshal(b, &got); err != nil {
			return err
		}
		for _, c := range got {
			out <- c
		}
		return nil
	})
	return s, out
}

// serveStub runs s.serve until the test ends, so a request made on the page
// reaches the wire the way it does live.
func serveStub(t *testing.T, s *apSession) {
	t.Helper()
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	go func() {
		_ = s.serve(ctx, s.cfg, func() feedConn { return s.cfg }, make(chan []byte), make(chan error, 1))
	}()
}

// drain discards the commands already recorded, so a test only sees what
// follows.
func drain(out <-chan map[string]any) {
	for {
		select {
		case <-out:
		default:
			return
		}
	}
}

// nextCmd waits for the next command a stub session sent.
func nextCmd(t *testing.T, out <-chan map[string]any) map[string]any {
	t.Helper()
	select {
	case c := <-out:
		return c
	case <-time.After(2 * time.Second):
		t.Fatal("no command reached the wire")
		return nil
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
	if conn["slot_data"] != true {
		t.Errorf("Connect must ask for slot data, which bounds the games hinted: %v", conn)
	}
}

// TestFeedHintItemsFollowIncludedGames pins the item suggestions: a Spyro 1+2
// seed must not offer Spyro 3 items, which the server has nowhere to place.
func TestFeedHintItemsFollowIncludedGames(t *testing.T) {
	f, s, _ := testSession(t)
	mustHandle(t, s, hintItemsPackageJS)
	mustHandle(t, s, hintConnectedS1S2JS)

	want := []string{"Flat Spyro Mode", "Spyro 1: Terrace Village Key", "Spyro 2: Glimmer Key"}
	if got := f.HintView().Items; !reflect.DeepEqual(got, want) {
		t.Fatalf("items = %v, want %v", got, want)
	}
}

// TestFeedHintItemsUnfilteredWithoutSlotData: a slot that reports no
// included_games keeps every name, as any other world's slot data is opaque.
func TestFeedHintItemsUnfilteredWithoutSlotData(t *testing.T) {
	f, s, _ := testSession(t)
	mustHandle(t, s, hintItemsPackageJS)
	mustHandle(t, s, hintConnectedNoGamesJS)

	if got := len(f.HintView().Items); got != 4 {
		t.Fatalf("items = %d, want all 4", got)
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
	srv := feedServer(t)
	f := NewFeed()
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	host := "ws://" + strings.TrimPrefix(srv.URL, "http://")
	go func() {
		f.Run(ctx, func() feedConn { return feedConn{Host: host, Slot: "SRTPlayer"} })
		close(done)
	}()

	v := waitForEvent(t, f)
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

// feedServer serves the handshake, data package, Connected and one ItemSend,
// then holds the connection open until the test ends.
func feedServer(t *testing.T) *httptest.Server {
	t.Helper()
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
	t.Cleanup(srv.Close)
	return srv
}

// waitForEvent blocks until the feed lists an event and returns that view.
func waitForEvent(t *testing.T, f *Feed) feedView {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for len(f.View().Events) == 0 && time.Now().Before(deadline) {
		time.Sleep(20 * time.Millisecond)
	}
	return f.View()
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

// TestFeedHintPointsCostAndLists pins the hint panel's numbers: the balance the
// room reports, the price one hint costs for this slot, and the names the form
// autocompletes.
func TestFeedHintPointsCostAndLists(t *testing.T) {
	f, s, _ := testSession(t)
	mustHandle(t, s, hintRoomInfoJS)
	mustHandle(t, s, dataPackageJS)
	mustHandle(t, s, hintConnectedJS)

	v := f.HintView()
	if !v.PointsKnown || v.Points != 30 {
		t.Fatalf("points = %d (known %v), want 30 (known)", v.Points, v.PointsKnown)
	}
	if v.Cost != 1 || v.Free {
		t.Fatalf("cost = %d (free %v), want 1 and not free", v.Cost, v.Free)
	}
	if want := []string{"Artisans: Free Lindar", "Artisans: Free Nevin"}; !reflect.DeepEqual(v.Missing, want) {
		t.Errorf("missing = %v, want %v", v.Missing, want)
	}
	if want := []string{"Dragon", "Terrace Village Key"}; !reflect.DeepEqual(v.Items, want) {
		t.Errorf("items = %v, want %v", v.Items, want)
	}

	mustHandle(t, s, `[{"cmd":"RoomUpdate","hint_points":42}]`)
	if got := f.HintView().Points; got != 42 {
		t.Errorf("points after RoomUpdate = %d, want 42", got)
	}
	mustHandle(t, s, `[{"cmd":"RoomUpdate","checked_locations":[102]}]`)
	v = f.HintView()
	if v.Points != 42 {
		t.Errorf("an absent hint_points must leave the balance alone, got %d", v.Points)
	}
	if want := []string{"Artisans: Free Lindar"}; !reflect.DeepEqual(v.Missing, want) {
		t.Errorf("missing after a check = %v, want %v", v.Missing, want)
	}
}

// TestHintCostFor pins the server's price formula: hint_cost is a percentage of
// the slot's location count, and any nonzero price is at least one point.
func TestHintCostFor(t *testing.T) {
	f := NewFeed()
	if got := f.hintCostFor(238); got != 0 {
		t.Errorf("unknown hint_cost = %d, want 0", got)
	}
	ten := 10.0
	f.setHintCost(&ten)
	if got := f.hintCostFor(238); got != 23 {
		t.Errorf("10%% of 238 = %d, want 23", got)
	}
	if got := f.hintCostFor(4); got != 1 {
		t.Errorf("a fractional point = %d, want the 1-point floor", got)
	}
	zero := 0.0
	f.setHintCost(&zero)
	if got := f.hintCostFor(238); got != 0 {
		t.Errorf("hint_cost 0 = %d, want free", got)
	}
}

// TestFeedSubscribesToHints pins where the hint list comes from: the slot's
// stored hints, read and watched after Connected, never written.
func TestFeedSubscribesToHints(t *testing.T) {
	_, s, sent := testSession(t)
	mustHandle(t, s, hintConnectedJS)

	if len(*sent) != 2 {
		t.Fatalf("want Get + SetNotify, got %v", *sent)
	}
	for i, want := range []string{"Get", "SetNotify"} {
		cmd := (*sent)[i]
		keys, ok := cmd["keys"].([]any)
		if cmd["cmd"] != want || !ok || len(keys) != 1 || keys[0] != "_read_hints_0_2" {
			t.Errorf("command %d = %v, want %s on _read_hints_0_2", i, cmd, want)
		}
	}
}

// TestFeedHintNamesResolve pins the hint list: Retrieved and SetReply each
// replace it whole, and every name comes from the data package.
func TestFeedHintNamesResolve(t *testing.T) {
	f, s, _ := testSession(t)
	mustHandle(t, s, dataPackageJS)
	mustHandle(t, s, hintConnectedJS)
	mustHandle(t, s, retrievedHintsJS)

	want := []feedHint{
		{ItemName: "Dragon", LocationName: "Artisans: Free Nestor",
			ReceiverName: "SRTPlayer", FinderName: "SRTPlayer", Progression: true},
		{ItemName: "1 Puzzle Piece", LocationName: "Artisans: Free Argus",
			ReceiverName: "SpeedyLink", FinderName: "SRTPlayer", Found: true},
	}
	if got := f.HintView().Hints; !reflect.DeepEqual(got, want) {
		t.Fatalf("hints = %+v, want %+v", got, want)
	}

	mustHandle(t, s, setReplyHintsJS)
	want = []feedHint{{ItemName: "1 Puzzle Piece", LocationName: "Merge 25 times",
		ReceiverName: "SpeedyLink", FinderName: "SpeedyLink", Found: true}}
	if got := f.HintView().Hints; !reflect.DeepEqual(got, want) {
		t.Errorf("hints after SetReply = %+v, want %+v", got, want)
	}
}

// TestFeedCommandResultBecomesNotice pins the requester's feedback: every text
// part of a CommandResult joins into one notice line.
func TestFeedCommandResultBecomesNotice(t *testing.T) {
	f, s, _ := testSession(t)
	mustHandle(t, s, hintConnectedJS)
	mustHandle(t, s, commandResultJS)

	want := "You can't afford the hint. You have 3 points and need at least 13."
	if got := f.HintView().Notice; got != want {
		t.Errorf("notice = %q, want %q", got, want)
	}
}

// TestFeedRequestHintSays pins the request path: the chat command goes out on
// the live connection as a Say.
func TestFeedRequestHintSays(t *testing.T) {
	f := NewFeed()
	s, out := stubSession(f, feedConn{Host: "127.0.0.1:38281", Slot: "SRTPlayer"})
	mustHandle(t, s, hintConnectedJS)
	drain(out)
	serveStub(t, s)

	if err := f.RequestHint("!hint_location Artisans: Free Nestor"); err != nil {
		t.Fatalf("RequestHint: %v", err)
	}
	got := nextCmd(t, out)
	if got["cmd"] != "Say" || got["text"] != "!hint_location Artisans: Free Nestor" {
		t.Errorf("wire = %v", got)
	}
}

// TestRequestHintNeedsAConnection pins the refusal: with no connection there is
// nothing to ask, and the page says so instead of queueing it.
func TestRequestHintNeedsAConnection(t *testing.T) {
	if err := NewFeed().RequestHint("!hint Dragon"); err == nil {
		t.Fatal("RequestHint must fail when nothing is connected")
	}
}

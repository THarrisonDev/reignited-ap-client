package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/coder/websocket"
)

// Live check feed: the launcher keeps its own text-only connection to the
// Archipelago room and lists every item the player's slot sends or receives.
// It reads server messages, not the game, so it stays accurate even when the
// in-game console garbles lines or the game crashes. It only listens: TextOnly
// tag, items_handling 0, and it never sends LocationChecks.

const (
	feedMaxEvents   = 200
	feedRetry       = 5 * time.Second
	flagProgression = 1
)

var (
	errConfigChanged = errors.New("connection settings changed")
	feedUUID         = fmt.Sprintf("srtap-launcher-%x", time.Now().UnixNano())
)

// FeedEvent is one item movement involving the player's slot.
type FeedEvent struct {
	Time        time.Time
	Kind        string // "sent", "received" or "found"
	Item        string
	Other       string // the receiver for "sent", the finder for "received"
	Location    string // empty for server grants
	Progression bool
}

type feedConn struct {
	Host, Slot, Password string
}

type feedView struct {
	Connected      bool
	Status         string
	Checked, Total int
	Events         []FeedEvent // newest first
}

// Feed is the shared state between the AP connection and the web page.
type Feed struct {
	mu        sync.Mutex
	connected bool
	status    string
	checked   int
	total     int
	events    []FeedEvent
}

func NewFeed() *Feed {
	return &Feed{status: "Starting…"}
}

func (f *Feed) View() feedView {
	f.mu.Lock()
	defer f.mu.Unlock()
	v := feedView{Connected: f.connected, Status: f.status, Checked: f.checked, Total: f.total}
	for i := len(f.events) - 1; i >= 0; i-- {
		v.Events = append(v.Events, f.events[i])
	}
	return v
}

func (f *Feed) setStatus(connected bool, status string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.connected, f.status = connected, status
}

func (f *Feed) setChecks(checked, total int) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.checked, f.total = checked, total
}

func (f *Feed) add(e FeedEvent) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.events = append(f.events, e)
	if len(f.events) > feedMaxEvents {
		f.events = f.events[len(f.events)-feedMaxEvents:]
	}
}

// Run keeps the feed connected to the room named by conf, reconnecting after
// drops and as soon as host/slot/password change. It returns when ctx ends.
func (f *Feed) Run(ctx context.Context, conf func() feedConn) {
	for ctx.Err() == nil {
		cfg := conf()
		if cfg.Slot == "" {
			f.setStatus(false, "Set a slot name above to follow your checks.")
		} else if err := f.runOnce(ctx, cfg, conf); errors.Is(err, errConfigChanged) {
			continue
		} else if err != nil && ctx.Err() == nil {
			f.setStatus(false, err.Error()+" Retrying…")
		}
		select {
		case <-ctx.Done():
		case <-time.After(feedRetry):
		}
	}
}

func (f *Feed) runOnce(ctx context.Context, cfg feedConn, conf func() feedConn) error {
	f.setStatus(false, "Connecting to "+cfg.Host+"…")
	c, err := dialFeed(ctx, cfg.Host)
	if err != nil {
		return fmt.Errorf("can't reach %s: is the server running?", cfg.Host)
	}
	defer func() { _ = c.CloseNow() }()
	c.SetReadLimit(64 << 20) // DataPackage for big games runs to megabytes

	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	msgs := make(chan []byte)
	readErr := make(chan error, 1)
	go func() {
		for {
			_, b, err := c.Read(ctx)
			if err != nil {
				readErr <- err
				return
			}
			select {
			case msgs <- b:
			case <-ctx.Done():
				return
			}
		}
	}()

	s := newAPSession(f, cfg, func(cmds ...any) error {
		b, err := json.Marshal(cmds)
		if err != nil {
			return err
		}
		wctx, wcancel := context.WithTimeout(ctx, 10*time.Second)
		defer wcancel()
		return c.Write(wctx, websocket.MessageText, b)
	})
	tick := time.NewTicker(2 * time.Second)
	defer tick.Stop()
	for {
		select {
		case b := <-msgs:
			if err := s.handle(b); err != nil {
				return err
			}
		case <-readErr:
			return fmt.Errorf("lost the connection to %s", cfg.Host)
		case <-tick.C:
			if conf() != cfg {
				return errConfigChanged
			}
		case <-ctx.Done():
			return ctx.Err()
		}
	}
}

// dialFeed connects like apclientpp does: an explicit scheme is used as-is,
// otherwise wss:// is tried before ws://.
func dialFeed(ctx context.Context, host string) (*websocket.Conn, error) {
	var last error
	for _, u := range feedURLs(host) {
		dctx, cancel := context.WithTimeout(ctx, 10*time.Second)
		c, _, err := websocket.Dial(dctx, u, nil)
		cancel()
		if err == nil {
			return c, nil
		}
		last = err
	}
	return nil, last
}

func feedURLs(host string) []string {
	h := normalizeHost(host)
	if h == "" {
		h = defaultHost
	}
	if strings.HasPrefix(h, "ws://") || strings.HasPrefix(h, "wss://") {
		return []string{h}
	}
	if _, _, err := net.SplitHostPort(h); err != nil {
		h += ":" + defaultPort
	}
	return []string{"wss://" + h, "ws://" + h}
}

// apSession decodes one connection's server messages into feed updates.
type apSession struct {
	feed    *Feed
	cfg     feedConn
	send    func(cmds ...any) error
	me      int
	alias   map[int]string
	game    map[int]string
	items   map[string]map[int64]string
	locs    map[string]map[int64]string
	checked map[int64]bool
	total   int
}

type apPlayer struct {
	Slot  int    `json:"slot"`
	Alias string `json:"alias"`
	Name  string `json:"name"`
}

func newAPSession(f *Feed, cfg feedConn, send func(cmds ...any) error) *apSession {
	return &apSession{
		feed: f, cfg: cfg, send: send,
		alias: map[int]string{}, game: map[int]string{},
		items: map[string]map[int64]string{}, locs: map[string]map[int64]string{},
		checked: map[int64]bool{},
	}
}

func (s *apSession) handle(b []byte) error {
	var cmds []json.RawMessage
	if json.Unmarshal(b, &cmds) != nil {
		//nolint:nilerr // not an array of commands (e.g. a single object frame)
		return nil
	}
	for _, raw := range cmds {
		var head struct {
			Cmd string `json:"cmd"`
		}
		if json.Unmarshal(raw, &head) != nil {
			continue
		}
		var err error
		switch head.Cmd {
		case "RoomInfo":
			err = s.onRoomInfo(raw)
		case "DataPackage":
			s.onDataPackage(raw)
		case "Connected":
			s.onConnected(raw)
		case "RoomUpdate":
			s.onRoomUpdate(raw)
		case "PrintJSON":
			s.onPrintJSON(raw)
		case "ConnectionRefused":
			err = s.onRefused(raw)
		}
		if err != nil {
			return err
		}
	}
	return nil
}

func (s *apSession) onRoomInfo(raw json.RawMessage) error {
	var m struct {
		Games []string `json:"games"`
	}
	_ = json.Unmarshal(raw, &m)
	getPkg := map[string]any{"cmd": "GetDataPackage"}
	if len(m.Games) > 0 {
		getPkg["games"] = m.Games
	}
	return s.send(getPkg, map[string]any{
		"cmd": "Connect", "game": "", "name": s.cfg.Slot, "password": s.cfg.Password,
		"uuid": feedUUID, "items_handling": 0, "tags": []string{"TextOnly"}, "slot_data": false,
		"version": map[string]any{"major": 0, "minor": 6, "build": 7, "class": "Version"},
	})
}

func (s *apSession) onDataPackage(raw json.RawMessage) {
	var m struct {
		Data struct {
			Games map[string]struct {
				Items     map[string]int64 `json:"item_name_to_id"`
				Locations map[string]int64 `json:"location_name_to_id"`
			} `json:"games"`
		} `json:"data"`
	}
	if json.Unmarshal(raw, &m) != nil {
		return
	}
	for g, pkg := range m.Data.Games {
		s.items[g] = invertIDs(pkg.Items)
		s.locs[g] = invertIDs(pkg.Locations)
	}
}

func (s *apSession) onConnected(raw json.RawMessage) {
	var m struct {
		Slot     int        `json:"slot"`
		Players  []apPlayer `json:"players"`
		SlotInfo map[string]struct {
			Game string `json:"game"`
		} `json:"slot_info"`
		Checked []int64 `json:"checked_locations"`
		Missing []int64 `json:"missing_locations"`
	}
	if json.Unmarshal(raw, &m) != nil {
		return
	}
	s.me = m.Slot
	s.setPlayers(m.Players)
	for k, v := range m.SlotInfo {
		if n, err := strconv.Atoi(k); err == nil {
			s.game[n] = v.Game
		}
	}
	s.checked = map[int64]bool{}
	s.mergeChecked(m.Checked)
	s.total = len(m.Checked) + len(m.Missing)
	s.feed.setChecks(len(s.checked), s.total)
	s.feed.setStatus(true, "Connected as "+s.cfg.Slot+".")
}

// mergeChecked marks the given location IDs as checked, ignoring duplicates.
func (s *apSession) mergeChecked(ids []int64) {
	for _, id := range ids {
		s.checked[id] = true
	}
}

func (s *apSession) onRoomUpdate(raw json.RawMessage) {
	var m struct {
		Players []apPlayer `json:"players"`
		Checked []int64    `json:"checked_locations"`
	}
	if json.Unmarshal(raw, &m) != nil {
		return
	}
	s.setPlayers(m.Players)
	s.mergeChecked(m.Checked)
	if s.total > 0 {
		s.feed.setChecks(len(s.checked), s.total)
	}
}

// ItemSend: item.player is the finder (whose world held the item), receiving
// is the slot that gets it.
func (s *apSession) onPrintJSON(raw json.RawMessage) {
	var m struct {
		Type      string `json:"type"`
		Receiving int    `json:"receiving"`
		Item      struct {
			Item     int64 `json:"item"`
			Location int64 `json:"location"`
			Player   int   `json:"player"`
			Flags    int   `json:"flags"`
		} `json:"item"`
	}
	if json.Unmarshal(raw, &m) != nil || s.me == 0 || (m.Type != "ItemSend" && m.Type != "ItemCheat") {
		return
	}
	finder, receiver := m.Item.Player, m.Receiving
	e := FeedEvent{
		Time:        time.Now(),
		Item:        s.itemName(receiver, m.Item.Item),
		Location:    s.locationName(finder, m.Item.Location),
		Progression: m.Item.Flags&flagProgression != 0,
	}
	switch {
	case finder == s.me && receiver == s.me:
		e.Kind = "found"
	case finder == s.me:
		e.Kind, e.Other = "sent", s.playerName(receiver)
	case receiver == s.me:
		e.Kind, e.Other = "received", s.playerName(finder)
	default:
		return
	}
	s.feed.add(e)
}

func (s *apSession) onRefused(raw json.RawMessage) error {
	var m struct {
		Errors []string `json:"errors"`
	}
	_ = json.Unmarshal(raw, &m)
	var why []string
	for _, e := range m.Errors {
		switch e {
		case "InvalidSlot":
			why = append(why, fmt.Sprintf("there is no slot named %q in this room", s.cfg.Slot))
		case "InvalidPassword":
			why = append(why, "the password is wrong")
		default:
			why = append(why, e)
		}
	}
	if len(why) == 0 {
		why = []string{"no reason given"}
	}
	return fmt.Errorf("the server refused the connection: %s", strings.Join(why, ", "))
}

func (s *apSession) setPlayers(players []apPlayer) {
	for _, p := range players {
		name := p.Alias
		if name == "" {
			name = p.Name
		}
		s.alias[p.Slot] = name
	}
}

func (s *apSession) itemName(player int, id int64) string {
	if n, ok := s.items[s.game[player]][id]; ok {
		return n
	}
	return fmt.Sprintf("Item #%d", id)
}

func (s *apSession) locationName(player int, id int64) string {
	if id <= 0 {
		return ""
	}
	if n, ok := s.locs[s.game[player]][id]; ok {
		return n
	}
	return fmt.Sprintf("Location #%d", id)
}

func (s *apSession) playerName(slot int) string {
	if slot == 0 {
		return "Archipelago"
	}
	if n := s.alias[slot]; n != "" {
		return n
	}
	return fmt.Sprintf("Player %d", slot)
}

func invertIDs(m map[string]int64) map[int64]string {
	out := make(map[int64]string, len(m))
	for name, id := range m {
		out[id] = name
	}
	return out
}

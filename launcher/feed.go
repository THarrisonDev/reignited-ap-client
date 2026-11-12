// Author: Tim Harrison
// Created: 2026-09-26
// Updated: 2026-11-11

package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/coder/websocket"
)

// Live check feed: the launcher keeps its own text-only connection to the
// Archipelago room and lists every item the player's slot sends or receives. It
// reads server messages rather than the game, so garbled console lines or a crash
// cost nothing. It sends no LocationChecks; the one command it sends for the
// player is a chat hint request from the Play tab.

const (
	feedMaxEvents   = 200
	feedRetry       = 5 * time.Second
	flagProgression = 1
)

var (
	errConfigChanged = errors.New("connection settings changed")
	errNotConnected  = errors.New("not connected to the server yet")
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

// feedHint is one hint the server holds for this slot: the item, where it is,
// who receives it and whether it has been found yet.
type feedHint struct {
	ItemName     string
	LocationName string
	ReceiverName string
	FinderName   string
	Progression  bool
	Found        bool
}

type feedView struct {
	Connected      bool
	Status         string
	Checked, Total int
	Events         []FeedEvent // newest first
}

// Feed is the shared state between the AP connection and the web page.
type Feed struct {
	mu          sync.Mutex
	connected   bool
	status      string
	checked     int
	total       int
	events      []FeedEvent
	points      int
	pointsKnown bool     // the room has reported the balance
	hintCost    *float64 // hint_cost, a percentage; nil until the room says
	hints       []feedHint
	notice      string
	missing     []string // unchecked location names, for autocomplete
	items       []string // item names of the player's own game
	hintReq     chan string
}

func NewFeed() *Feed {
	return &Feed{status: "Starting…", hintReq: make(chan string, 1)}
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

func (f *Feed) setPoints(n int) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.points, f.pointsKnown = n, true
}

// setHintCost records the room's hint price, a percentage of the slot's
// location count.
func (f *Feed) setHintCost(percent *float64) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.hintCost = percent
}

func (f *Feed) setHints(hints []feedHint) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.hints = hints
}

// setLists stores the hint form's autocomplete names, in name order.
func (f *Feed) setLists(missing, items []string) {
	sort.Strings(missing)
	sort.Strings(items)
	f.mu.Lock()
	defer f.mu.Unlock()
	f.missing, f.items = missing, items
}

// SetNotice shows the server's answer to the last hint request.
func (f *Feed) SetNotice(text string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.notice = text
}

// RequestHint hands a chat command to the live connection. With none up the
// request is dropped rather than queued for a later session.
func (f *Feed) RequestHint(text string) error {
	f.mu.Lock()
	if !f.connected {
		f.mu.Unlock()
		return errNotConnected
	}
	f.notice = ""
	f.mu.Unlock()
	select {
	case f.hintReq <- text:
	default:
	}
	return nil
}

// hintCostFor is the server's price for one hint across a slot holding total
// locations: hint_cost is a percentage, and any nonzero price is at least one
// point.
func (f *Feed) hintCostFor(total int) int {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.hintCost == nil || *f.hintCost == 0 {
		return 0
	}
	return max(1, int(*f.hintCost*0.01*float64(total)))
}

// HintView returns the hint panel's state for the page and its polled fragment.
func (f *Feed) HintView() hintView {
	f.mu.Lock()
	v := hintView{
		Connected:   f.connected,
		Points:      f.points,
		PointsKnown: f.pointsKnown,
		Hints:       append([]feedHint(nil), f.hints...),
		Missing:     append([]string(nil), f.missing...),
		Items:       append([]string(nil), f.items...),
		Notice:      f.notice,
	}
	total := f.total
	f.mu.Unlock()
	// outside the lock: the price formula lives in hintCostFor, which locks
	v.Cost = f.hintCostFor(total)
	v.Free = v.Cost == 0
	return v
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
	msgs, readErr := readMessages(ctx, c)
	s := newAPSession(f, cfg, writeTo(ctx, c))
	return s.serve(ctx, cfg, conf, msgs, readErr)
}

// readMessages streams the connection's frames and reports a read failure.
func readMessages(ctx context.Context, c *websocket.Conn) (<-chan []byte, <-chan error) {
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
	return msgs, readErr
}

// writeTo sends encoded commands on the session's connection.
func writeTo(ctx context.Context, c *websocket.Conn) func(cmds ...any) error {
	return func(cmds ...any) error {
		b, err := json.Marshal(cmds)
		if err != nil {
			return err
		}
		wctx, wcancel := context.WithTimeout(ctx, 10*time.Second)
		defer wcancel()
		return c.Write(wctx, websocket.MessageText, b)
	}
}

// serve applies server messages until the connection drops, the settings
// change, or ctx ends.
func (s *apSession) serve(ctx context.Context, cfg feedConn, conf func() feedConn,
	msgs <-chan []byte, readErr <-chan error) error {
	tick := time.NewTicker(2 * time.Second)
	defer tick.Stop()
	for {
		select {
		case b := <-msgs:
			if err := s.handle(b); err != nil {
				return err
			}
		case err := <-readErr:
			return lostConnection(cfg, err)
		case <-tick.C:
			if conf() != cfg {
				return errConfigChanged
			}
		case text := <-s.feed.hintReq:
			if err := s.say(text); err != nil {
				return err
			}
		case <-ctx.Done():
			return ctx.Err()
		}
	}
}

// lostConnection reports a dropped connection, with the socket's reason when it
// gave one.
func lostConnection(cfg feedConn, err error) error {
	if err != nil {
		return fmt.Errorf("lost the connection to %s: %w", cfg.Host, err)
	}
	return fmt.Errorf("lost the connection to %s", cfg.Host)
}

// say sends one chat line, which is how a hint request reaches the server.
func (s *apSession) say(text string) error {
	return s.send(map[string]any{"cmd": "Say", "text": text})
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
	feed     *Feed
	cfg      feedConn
	send     func(cmds ...any) error
	me       int
	alias    map[int]string
	game     map[int]string
	items    map[string]map[int64]string
	locs     map[string]map[int64]string
	checked  map[int64]bool
	missing  map[int64]bool
	included []string // the slot's included games, empty when it reports none
	total    int
}

type apPlayer struct {
	Slot  int    `json:"slot"`
	Alias string `json:"alias"`
	Name  string `json:"name"`
}

type apSlotInfo struct {
	Game string `json:"game"`
}

type apConnected struct {
	Slot       int                   `json:"slot"`
	HintPoints *int                  `json:"hint_points"`
	Players    []apPlayer            `json:"players"`
	SlotInfo   map[string]apSlotInfo `json:"slot_info"`
	SlotData   apSlotData            `json:"slot_data"`
	Checked    []int64               `json:"checked_locations"`
	Missing    []int64               `json:"missing_locations"`
}

// apSlotData is the part of a world's slot data the launcher reads: the games
// this slot actually includes, which bound the items it can be sent.
type apSlotData struct {
	IncludedGames []string `json:"included_games"`
}

// apHint is one record of the room's stored hint list for this slot.
type apHint struct {
	Receiving int   `json:"receiving_player"`
	Finding   int   `json:"finding_player"`
	Location  int64 `json:"location"`
	Item      int64 `json:"item"`
	Found     bool  `json:"found"`
	Flags     int   `json:"item_flags"`
}

type apText struct {
	Text string `json:"text"`
}

type apItem struct {
	Item     int64 `json:"item"`
	Location int64 `json:"location"`
	Player   int   `json:"player"`
	Flags    int   `json:"flags"`
}

type apPrint struct {
	Type      string   `json:"type"`
	Data      []apText `json:"data"`
	Receiving int      `json:"receiving"`
	Item      apItem   `json:"item"`
}

func newAPSession(f *Feed, cfg feedConn, send func(cmds ...any) error) *apSession {
	return &apSession{
		feed: f, cfg: cfg, send: send,
		alias: map[int]string{}, game: map[int]string{},
		items: map[string]map[int64]string{}, locs: map[string]map[int64]string{},
		checked: map[int64]bool{}, missing: map[int64]bool{},
	}
}

func (s *apSession) handle(b []byte) error {
	var cmds []json.RawMessage
	if json.Unmarshal(b, &cmds) != nil {
		//nolint:nilerr // not an array of commands (e.g. a single object frame)
		return nil
	}
	for _, raw := range cmds {
		if err := s.dispatch(raw); err != nil {
			return err
		}
	}
	return nil
}

// dispatch applies one server command.
func (s *apSession) dispatch(raw json.RawMessage) error {
	switch cmdName(raw) {
	case "RoomInfo":
		return s.onRoomInfo(raw)
	case "DataPackage":
		s.onDataPackage(raw)
	case "Connected":
		return s.onConnected(raw)
	case "RoomUpdate":
		s.onRoomUpdate(raw)
	case "PrintJSON":
		s.onPrintJSON(raw)
	case "Retrieved":
		s.onRetrieved(raw)
	case "SetReply":
		s.onSetReply(raw)
	case "ConnectionRefused":
		return s.onRefused(raw)
	}
	return nil
}

// cmdName is the command a raw server message names, empty when it names none.
func cmdName(raw json.RawMessage) string {
	var head struct {
		Cmd string `json:"cmd"`
	}
	_ = json.Unmarshal(raw, &head)
	return head.Cmd
}

func (s *apSession) onRoomInfo(raw json.RawMessage) error {
	var m struct {
		Games    []string `json:"games"`
		HintCost *float64 `json:"hint_cost"`
	}
	_ = json.Unmarshal(raw, &m)
	s.feed.setHintCost(m.HintCost)
	getPkg := map[string]any{"cmd": "GetDataPackage"}
	if len(m.Games) > 0 {
		getPkg["games"] = m.Games
	}
	return s.send(getPkg, map[string]any{
		"cmd": "Connect", "game": "", "name": s.cfg.Slot, "password": s.cfg.Password,
		"uuid": feedUUID, "items_handling": 0, "tags": []string{"TextOnly"}, "slot_data": true,
		"version": map[string]any{"major": 0, "minor": 6, "build": 8, "class": "Version"},
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

func (s *apSession) onConnected(raw json.RawMessage) error {
	var m apConnected
	_ = json.Unmarshal(raw, &m)
	s.me = m.Slot
	s.setPlayers(m.Players)
	s.setGames(m.SlotInfo)
	s.checked, s.missing = map[int64]bool{}, map[int64]bool{}
	for _, id := range m.Missing {
		s.missing[id] = true
	}
	s.total = len(m.Checked) + len(m.Missing)
	s.included = m.SlotData.IncludedGames
	s.addChecked(m.Checked)
	if m.HintPoints != nil {
		s.feed.setPoints(*m.HintPoints)
	}
	s.feed.setStatus(true, "Connected as "+s.cfg.Slot+".")
	return s.send(hintSubscriptions(s.hintKey())...)
}

// setGames records each slot's game, which keys the item and location names.
func (s *apSession) setGames(info map[string]apSlotInfo) {
	for k, v := range info {
		if n, err := strconv.Atoi(k); err == nil {
			s.game[n] = v.Game
		}
	}
}

// hintKey is the server-side key holding this slot's hints. It is read-only:
// the server rewrites it, so nothing here ever sends Set on it.
func (s *apSession) hintKey() string {
	return fmt.Sprintf("_read_hints_0_%d", s.me)
}

// hintSubscriptions asks for this slot's stored hints and then keeps them live.
func hintSubscriptions(key string) []any {
	return []any{
		map[string]any{"cmd": "Get", "keys": []string{key}},
		map[string]any{"cmd": "SetNotify", "keys": []string{key}},
	}
}

// mergeChecked marks the given location IDs as checked, ignoring duplicates.
func (s *apSession) mergeChecked(ids []int64) {
	for _, id := range ids {
		s.checked[id] = true
	}
}

// addChecked records newly checked locations and refreshes the counts and the
// hint form's unchecked names.
func (s *apSession) addChecked(ids []int64) {
	s.mergeChecked(ids)
	for _, id := range ids {
		delete(s.missing, id)
	}
	if s.total > 0 {
		s.feed.setChecks(len(s.checked), s.total)
	}
	s.publishLists()
}

// publishLists hands the hint form the names it autocompletes: the slot's
// unchecked locations and the item names of its own game.
func (s *apSession) publishLists() {
	game := s.game[s.me]
	missing := make([]string, 0, len(s.missing))
	for id := range s.missing {
		if n, ok := s.locs[game][id]; ok {
			missing = append(missing, n)
		}
	}
	items := make([]string, 0, len(s.items[game]))
	for _, n := range s.items[game] {
		if s.offerItem(n) {
			items = append(items, n)
		}
	}
	s.feed.setLists(missing, items)
}

// offerItem reports whether a hint for this item can reach the slot: items of a
// game the slot excludes never can. Slot data names games by key ("spyro1"), item
// names by display name ("Spyro 1: …"), so both sides are folded before comparing.
func (s *apSession) offerItem(name string) bool {
	if len(s.included) == 0 {
		return true
	}
	sep := strings.Index(name, ": ")
	if sep < 0 {
		return true
	}
	prefix := foldGame(name[:sep])
	for _, g := range s.included {
		if foldGame(g) == prefix {
			return true
		}
	}
	return false
}

// foldGame compares game names the way item prefixes and slot-data keys spell
// them: "Spyro 1", "spyro1" and "SPYRO 1" all fold together.
func foldGame(name string) string {
	return strings.ToLower(strings.ReplaceAll(name, " ", ""))
}

func (s *apSession) onRoomUpdate(raw json.RawMessage) {
	var m struct {
		Players    []apPlayer `json:"players"`
		Checked    []int64    `json:"checked_locations"`
		HintPoints *int       `json:"hint_points"`
	}
	if json.Unmarshal(raw, &m) != nil {
		return
	}
	s.setPlayers(m.Players)
	s.addChecked(m.Checked)
	if m.HintPoints != nil {
		s.feed.setPoints(*m.HintPoints)
	}
}

// onRetrieved applies the answer to our hint subscription.
func (s *apSession) onRetrieved(raw json.RawMessage) {
	var m struct {
		Keys map[string]json.RawMessage `json:"keys"`
	}
	if json.Unmarshal(raw, &m) != nil {
		return
	}
	s.applyHints(m.Keys[s.hintKey()])
}

// onSetReply applies a later replacement of the hint list, which the server
// pushes because we subscribed to it.
func (s *apSession) onSetReply(raw json.RawMessage) {
	var m struct {
		Key   string          `json:"key"`
		Value json.RawMessage `json:"value"`
	}
	if json.Unmarshal(raw, &m) != nil || m.Key != s.hintKey() {
		return
	}
	s.applyHints(m.Value)
}

// applyHints replaces the whole hint list from a payload of hint records.
func (s *apSession) applyHints(b json.RawMessage) {
	var recs []apHint
	if json.Unmarshal(b, &recs) != nil {
		return
	}
	hints := make([]feedHint, 0, len(recs))
	for _, r := range recs {
		hints = append(hints, s.hint(r))
	}
	s.feed.setHints(hints)
}

// hint names one hint record: the item belongs to the receiving slot's game and
// the location to the finding slot's.
func (s *apSession) hint(r apHint) feedHint {
	return feedHint{
		ItemName:     s.itemName(r.Receiving, r.Item),
		LocationName: s.locationName(r.Finding, r.Location),
		ReceiverName: s.playerName(r.Receiving),
		FinderName:   s.playerName(r.Finding),
		Progression:  r.Flags&flagProgression != 0,
		Found:        r.Found,
	}
}

// onPrintJSON shows the requester's CommandResult text as the hint notice, and
// keeps the item feed: item.player is the finder (whose world held the item),
// receiving is the slot that gets it.
func (s *apSession) onPrintJSON(raw json.RawMessage) {
	var m apPrint
	if json.Unmarshal(raw, &m) != nil {
		return
	}
	if m.Type == "CommandResult" {
		s.feed.SetNotice(commandText(m.Data))
		return
	}
	if s.me == 0 || (m.Type != "ItemSend" && m.Type != "ItemCheat") {
		return
	}
	if e, ok := s.movement(m); ok {
		s.feed.add(e)
	}
}

// commandText joins the text parts of one server line.
func commandText(parts []apText) string {
	var b strings.Builder
	for _, p := range parts {
		b.WriteString(p.Text)
	}
	return strings.TrimSpace(b.String())
}

// movement turns an item movement into a feed event, reporting false when
// neither end is this slot.
func (s *apSession) movement(m apPrint) (FeedEvent, bool) {
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
		return FeedEvent{}, false
	}
	return e, true
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

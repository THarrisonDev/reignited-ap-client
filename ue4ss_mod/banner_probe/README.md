# banner_probe

Independent UE4SS probe mod. Answers the four questions that decide how
`srt_bridge/hud_banner.lua` shows received items, sent checks and checkd
notices — whether the fanfare window can be extended or held open, whether we
can spawn a fanfare widget of our own, and whether the HUD's canvas can draw
text instead of the fanfare at all.

What is already proven lives in `docs/fanfare_text.md`. The API surface comes
from `docs/falcon_sdk_dump/UI_FanFareMessage.hpp` (the widget: `Intro`/`Outro`
animations, `State`, `message text` — no duration field), `UMG.hpp`
(`SetPlaybackSpeed`, `PauseAnimation`, `PlayAnimation`, `GetEndTime`,
`WidgetBlueprintLibrary::Create`, `AddToViewport`) and `Engine.hpp`
(`AHUD:ReceiveDrawHUD`, `UCanvas:K2_DrawText`, `UEngine.SubtitleFont`).

Read-only against the save: message text and widget lifetimes only, no
progression writes. It does disturb the live fanfare widget — that is the point,
and **0** puts it back.

## Responsible AI Usage Disclosure

This project was written while leveraging open-weight large
language models, primarily self-hosted with open source tools.
All usage happened within a controlled development workflow and
was narrowly spec'd by the developer. This workflow has
been provided including all tools and processes. It can be found in each
project in the [PROCESS.md](https://github.com/THarrisonDev/reignited-ap/blob/main/PROCESS.md) on root.

Remember, these things are tools meant to EMPOWER you never stop thinking.

 **Brains > Bots <3**
 -Tim

Contributors are held to the same expectation. AI-assisted contributions are
welcome, but the human author owns the result: correctness, legibility,
tests, and the decision to merge. Say so in your pull request — disclosure is
there to keep review honest, not to reject a change. We will not be accepting
any code generated in a blind agentic manner and will automatically reject any
PRs directly attributed to AI tools.

## Install

Same shape as the other probes in the mods tree (`egg_gate_probe`,
`dragon_query_probe`): a folder holding `Scripts/main.lua`, no `mod.json`, and a
`mods.txt` line. From the repo root:

```
MODS="$HOME/.local/share/Steam/steamapps/common/Spyro Reignited Trilogy/Falcon/Binaries/Win64/Mods"
cp -R client/ue4ss_mod/banner_probe "$MODS/banner_probe"
printf 'banner_probe : 1\n' >> "$MODS/mods.txt"
```

UE4SS loads Lua at startup, so **restart the game** after copying. When the run
is done, flip the line to `banner_probe : 0` (the house convention — every other
probe sits at 0) or delete the folder.

Leave `srt_bridge` enabled — it only fires its own banner when an item arrives
or a check is sent, so don't pick anything up while probing and the log stays
clean. Run the probe **in play**, not in a menu: the HUD and fanfare widget only
exist in play.

## Keys

The number row, which nothing in the game binds (and no F keys on this keyboard):

| Key | What it does |
| --- | --- |
| `1` | fires a normal dragon fanfare, writes a sentinel, logs the window |
| `2` | same, then `SetPlaybackSpeed(Intro, 0.25)` — asks for a ~4x window |
| `3` | same, then `PauseAnimation(Intro)` — asks the banner to stay |
| `4` | `WidgetBlueprintLibrary:Create` a second fanfare widget, drive it, drop it |
| `5` | hooks `/Script/Engine.HUD:ReceiveDrawHUD` and draws text on the canvas |
| `6` | runs checks 1→3 back to back (~35s) — 4 and 5 stay on their own keys |
| `7` | **burst**: hold one window open and swap the text 5× like a run of received items |

Run it with `srt_bridge : 0`. Press `1` on its own first, and wait ~10s after
picking a save. If it dies, the last `[PROBE]` line names the step: waiting (no
fanfare fired), `calling ShowFanfare`, `ShowFanfare returned`, or
`window @…` (sampling).
| `0` | abort: normal playback, stop animations, `State = 0`, remove our widget, unhook |

One check at a time: a key pressed while a check runs is ignored (the log says
`busy`). `0` works at any time, including mid-check.

## The three failures, and why production never sees them

v3 crashed, v4 crashed, v5 hung with the CPU pinned. The code that matters is
identical to `hud_banner.lua` (wait for `State == 0`, fire `ShowFanfare`, write
at +100 ms, re-assert) — the difference was the *scheduling*:

- `hud_banner.lua` has exactly one shape: `ExecuteWithDelay(ms, →)
  ExecuteInGameThread(fn)` — the async tick hands work to the game thread.
- The probe called `ExecuteInGameThread(step)` from the end of `watch()`, which
  is *already* inside a game-thread job. That is a game-thread job scheduling a
  game-thread job, i.e. a job that waits on the queue of the thread it is
  running on: the wedge in v5.

v7 calls `step()` directly (callers are already on the game thread) and the spec
now flags any nested `ExecuteInGameThread` as a failure, so the class of bug
cannot come back unnoticed. The earlier v3 crash was a separate, plainer
mistake (colon call adding an argument to `ShowFanfare`); v4 fired while a
fanfare was already showing.

The bridge can stay enabled: its banners can interleave with a probe window, so
a `window @…` line that goes `state=1 → 0 → 1` is the bridge showing its own
item, not the probe's window closing twice.

## Session 1 result: the window IS ours (18 Oct 2026)

Checks 2 and 3 both worked on screen — `SetPlaybackSpeed(Intro, 0.25)` stretched
the banner, and `PauseAnimation(Intro)` held it, so a single window can be kept
up as long as we want. One cosmetic wrinkle: holding freezes the Intro
mid-render, so the glow is left part-way and can obscure the text. Each `7`
press therefore freezes at the next of `300 / 450 / 580 ms` into the ~0.6s Intro,
so the settled frame can be found by pressing it a few times; the log line
`burst: froze at <time>` says which freeze point that run used. If no freeze
point is clean, the fallback is hiding the glow overlays
(`gloweffect`, `glowintro`, `Pulse`, `Sparkle`) with `SetVisibility(Hidden)`.

The 2.8s figure is still a latent `Delay` in the widget's ubergraph, but it no
longer matters: `PauseAnimation` pre-empts the finish, so the Outro never runs
and the window stays until we release it.

## First runs (18 Oct 2026): two crashes and a hang, all at the first fanfare

v3 and v4 died the moment a check fired its first fanfare; v5 got further —
`ShowFanfare returned`, then `fanfare: writing text`, then the game wedged with
the CPU pinned and had to be killed. The presses were seconds after the slot
connected, i.e. while the game was showing counter fanfares and srt_bridge was
replaying its item backlog through the same widget. So two things were wrong:
the probe injected into a busy window (production waits for `State == 0`), and
it was a second writer racing the bridge.

v6: check 1 measures the window with **no text write at all** (firing and
sampling only), every write is skipped if the window is not open at +100 ms, and
the probe is meant to run with `srt_bridge : 0`. The fanfare steps now log the
whole sequence, so a failure names its step:

```
fanfare: waiting for an idle widget
fanfare: calling ShowFanfare
fanfare: ShowFanfare returned
fanfare: writing text
```

The lengths captured before the first crash already answer the main question:

```
window anim Intro: start=0.0 end=0.60000002384186
window anim Outro: start=0.0 end=0.26666668057442
```

`0.6 + 0.267 = 0.87s`, nowhere near the measured ~2.8s window. So the window is
**not** the Intro animation: the remaining ~2s is almost certainly a latent
`Delay` node in the widget's ubergraph (the kismet dumps import
`KismetSystemLibrary->Delay`), which is exactly what the user suspected and what
`SetPlaybackSpeed`/`PauseAnimation` cannot touch. Checks 2 and 3 now test that
rather than assuming otherwise.

The crash itself was the probe's fault, not the game's: it called
`h:ShowFanfare(...)` with a colon (explicit self), where `hud_banner.lua` calls
`hud.ShowFanfare(...)` with a dot. A wrong UFunction call shape is a native
crash, so `pcall` never sees it. v4 calls it exactly like production and logs a
`fanfare: calling ShowFanfare` breadcrumb first, so a repeat crash still names
the culprit. `6` now only runs the three window checks; 4 (spawn) and 5
(canvas) are separate presses because those are the remaining crash candidates.

## Readout

Every line lands in `BannerProbe.log` beside the script, and on the UE4SS
console as `[PROBE]`.

Load line:

```
banner_probe v3 loaded; 1..5 checks, 6 all, 0 abort
```

**1. window** — baseline, and the animation lengths the duration actually comes
from:

```
window anim Intro: start=0.0 end=2.5
window anim Outro: start=0.0 end=0.3
window @100ms state=1 anim=0.1 base='Rescued ' prop='SRT_PROBE_WINDOW'
window done: opened=1000ms last_state1=2700ms closed=2800ms
```

**2. extend** — the window with Intro slowed 4x. `done: last_state1=` above
~8000 ms means the window is ours to stretch:

```
extend: speed set, playing=true time=0.1
extend done: opened=..., last_state1=..., closed=...
extend: speed restored to 1.0
```

**3. hold** — `PauseAnimation` at ~100ms, then 12s of sampling. `state=1` for the
whole run, `prop` holding the sentinel, and no `state=0` line means the banner
can be held open and fed line by line:

```
hold: paused at 0.1
hold: playing=false
hold @100ms state=1 anim=0.1 base='Rescued ' prop='SRT_PROBE_HOLD'
hold done: opened=0ms last_state1=11900ms closed=nil
```

**7. burst** — the design test: one held window, five swapped lines:

```
== 6. burst: freeze Intro at 300ms, then swap text
burst: froze at 0.31
burst: writing 'SRT ITEM 1/5'
burst 1: state=1 base='SRT ITEM 1/5' prop='SRT ITEM 1/5'
...
burst done: swaps=5 prop_ok=5 base_ok=5 open_frames=5 still_open=true
```

`prop_ok` counts writes the property held, `base_ok` the ones the player's
TextBlock actually showed, `open_frames` the samples where the window was still
open. Five-in, five-held, still-open is the green light for burst mode: one
fanfare carries a whole run of items, and `hud_banner`'s 3s gate, re-assert
schedule and idle wait all disappear. If `base_ok` is low while `prop_ok` is 5,
the display is being repainted from the canned text while frozen — then the fix
is a per-frame re-assert (a `Tick` hook) rather than a per-banner one.

**4. spawn** — our own widget, which would let us own the lifetime outright:

```
spawn: src class=Class /Game/.../UI_FanFareMessage_C
spawn: created UI_FanFareMessage_C_...
spawn anim Intro: start=0.0 end=2.5
spawn: Show Message spelling=Show Message
spawn: widget removed
```

`Show Message spelling=nil` means the BP function name did not resolve; the text
write alone still went in, so watch the screen.

**5. canvas** — text drawn from the HUD's own draw pass, no widget involved:

```
canvas: engine=true font=true
canvas: hook ids=11,12
canvas: ReceiveDrawHUD fired, size=1920x1080
canvas: K2_DrawText form=1 (named struct fields)
canvas: done, ReceiveDrawHUD fired 480 times
```

`K2_DrawText form=1`/`form=2` records which way UE4SS took the struct arguments;
`rejected both argument forms` means we know the call shape is wrong, not that the
canvas path is dead. `fired 0 times` means the HUD's draw pass never runs (look
at `bShowHUD`), so the canvas route is off the table.

## What each result buys

| Result | Consequence |
| --- | --- |
| 2 extends the window | one fanfare per burst, stream lines into it with our own timing; the 3s display gate, the re-assert schedule and the idle wait all go away |
| 3 holds the window | the same, plus a burst can stay up until we close it — no fanfare per item at all |
| 4 spawns a widget | stop borrowing the game's widget: own instance, own lifetime, no connect collision, no `State` races |
| 5 draws text | no widget at all; cheapest per frame, but unstyled (engine font, our own position/backdrop) |
| none of them | today's recipe stays; the stripped `hud_banner.lua` is the floor |

Record whichever answers come back in `docs/fanfare_text.md` (a short section
per check, with the log excerpt), then delete this mod — it is a probe, not a
feature.

## Notes

- `0` also writes `State = 0` and replays the `Outro`, so a paused Intro
  cannot leave the widget frozen on screen. If a check wedged the game's banner
  queue anyway, that is the recovery; a restart is the fallback.
- The probe never writes save data, only widget text and widget lifetimes.
- Lua spec: `client/tests/lua/test_banner_probe.lua` fakes the whole UE4SS
  surface, so every path above is executed (arguably) without a game session.

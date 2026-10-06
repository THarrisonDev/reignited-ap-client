# fanfare_test

Independent UE4SS probe mod. Measures how long the HUD fanfare banner
(`UI_FanFareMessage_C`, the "x/x dragons!" popup) stays on screen, so
`srt_bridge/hud_banner.lua` can space its text re-asserts and its banner
queue against the real window length.

See `docs/fanfare_text.md` and `docs/falcon_sdk_dump/UI_FanFareMessage.hpp`.
The probe samples the widget `State` (0=idle, 1=showing), `Base:GetText()`
(the text the player actually sees), and the `message text` property. It
exists to (1) measure the window length and (2) catch the display reverting
to the canned "Rescued ..." while the property still holds our write.

## Responsible AI Usage Disclosure

This project was written while leveraging open-weight large
language models, primarily self-hosted with open source tools.
All usage happened within a controlled development workflow and
was narrowly spec'd by the developer. This workflow has been
provided including all tools and processes. It can be found in each
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

Copy this folder next to the srt_bridge mod in the game's UE4SS mods
directory and add to mods.txt:

```
fanfare_test : 1
```

Lua-only, read-only against the save — no progression writes.

## Use

Load must show `fanfare_test v6 loaded` in UE4SS.log; if not, copy it again
(v1 crashed the game at load: nonexistent `defines.KEY_DELETE` constant).
UE4SS loads Lua at startup, so **restart the game** after copying an update.

Press **DEL** during gameplay (not menus). It fires one dragon fanfare, waits
100ms (the production recipe), writes a sentinel into the banner text, then
samples every 25ms for 12s, logging every transition of `state`/`base`/`prop`.

`Base:GetText()` (what the player sees) and the `message text` property (what
we wrote) are sampled separately: the game's own Tick/binding can repaint Base
back to "Rescued ..." while the property still holds our sentinel. The
`message text` property persists after the banner leaves and `IsVisible()` is
always true, so neither is a closure signal; `State` is.

Results log to `FanfareTest.log` next to this script and the UE4SS console
(`[FANFARE]` lines).

## Expected readout

A baseline line, a timeline of transitions, then a summary:

```
lifetime probe: baseline state=0 base='Rescued ' prop='Rescued '
lifetime @25ms state=1 base='SRT_LIFETIME_PROBE' prop='SRT_LIFETIME_PROBE'
lifetime @1800ms state=1 base='Rescued ' prop='SRT_LIFETIME_PROBE'   <- leak!
lifetime @2725ms state=0 base='Rescued ' prop='SRT_LIFETIME_PROBE'
lifetime probe done: last_visible~2725ms tail ...
```

`last_visible~Nms` is the banner duration (~2.7s in-game). A `base` line that
reverts to `'Rescued '` while `prop` still holds the sentinel is the display
leak; note the timestamp, which is when a re-assert is needed.

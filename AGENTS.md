# AGENTS.md

This file provides guidance to Codex (Codex.ai/code) when working with code in this repository.

## What this project is

`galaxy` — a portrait-orientation mobile prototype of a 4X-style star map. A
single integer seed deterministically generates a spiral galaxy of ~220 star
systems joined by a non-crossing hyperlane network, carved into named regions,
rendered on a world much larger than the viewport that the player pans and
zooms around.

A local **Nakama** backend (docker compose) authenticates by device id and is
authoritative for the map: it generates the galaxy and ships it to the client.
The client keeps its own copy of the generator purely as an offline fallback.

Git: a single `main` branch pushed straight to `origin`; there is no review flow.

## Toolchain

Two separate installs, and **they are different engine versions**:

| Tool | Path | Version |
|---|---|---|
| Editor (GUI) | `/Applications/Defold.app` | 1.13.1 (`574678c7`) |
| `bob.jar` (CLI builder) | `~/Defold/bob.jar` | 1.12.4 (`402218d5`) |
| Headless engine | `~/Defold/dmengine_headless-402218d5544666871f07ecdfa21032a7fb59413f-arm64-macos` | 1.12.4, matches bob |

Prefer the editor HTTP API (below) for anything the user will also see in the editor, so the engine version matches. Use the CLI path for headless/automated runs.

## Commands

### CLI build

`bob.jar` is compiled for Java 25; the system `java` (SDKMAN, Java 21) fails with `UnsupportedClassVersionError`. Use the JDK bundled with the editor:

```bash
/Applications/Defold.app/Contents/Resources/packages/jdk-25+36/bin/java -jar ~/Defold/bob-1.13.1.jar resolve build
```

`resolve` fetches library dependencies (no-op while `[project] dependencies` is empty); drop it for a faster inner loop. Output lands in `build/default/` (gitignored). Add `distclean` before `build` for a clean rebuild.

### Headless run

Point the engine at the compiled project file, not the directory:

```bash
~/Defold/dmengine_headless-402218d5544666871f07ecdfa21032a7fb59413f-arm64-macos ./build/default/game.projectc
```

It runs until killed. It opens a log server, an engine service on port 8001, and a Remotery profiler on 17815 — running two instances at once will collide on 8001.

### Editor HTTP API

When the editor has this project open it serves a local REST API. Port and bearer token are written to `.internal/editor.port` and `.internal/editor.token` (both gitignored, both change per editor session — always re-read them, never hardcode). `/eval`, `/command/*`, and `/prefs/*` require `Authorization: Bearer <token>`; `/console` does not.

```bash
PORT=$(cat .internal/editor.port); TOK=$(cat .internal/editor.token)

curl -s -X POST -H "Authorization: Bearer $TOK" localhost:$PORT/command/build        # build and run
curl -s -X POST -H "Authorization: Bearer $TOK" localhost:$PORT/command/hot-reload   # push edits into the running game
curl -s localhost:$PORT/console                                                      # read console output as JSON
curl -sN localhost:$PORT/console/stream                                              # follow console output
curl -s -X POST -H "Authorization: Bearer $TOK" --data "return editor.get('/game.project','path')" localhost:$PORT/eval
curl -s -o preview.png "localhost:$PORT/preview/main/main.collection?width=800&height=600"
```

`GET localhost:$PORT/openapi.json` is the full spec and `POST /command/{command}` documents every command in its description — `clean-build`, `build-html5`, `rebundle`, `fetch-libraries`, `reload-extensions`, and the `debugger-*` family. `GET /ref` returns the complete engine + editor Lua API reference as JSON, which is the fastest way to check an API signature without leaving the shell.

Hot-reload is the normal edit loop: change a `.script`/`.lua`, POST `hot-reload`, read `/console`. Only fall back to a full `build` for changes hot-reload can't pick up.

### Generation, outside the engine

`galaxy/` is pure Lua with no engine dependency, so the whole generator runs
under standalone `luajit` (installed at `/opt/homebrew/bin/luajit`, the same
LuaJIT 2.1 the engine embeds). This is by far the fastest way to iterate on
generation — no build, no window, ~50 ms per galaxy:

```bash
luajit tools/verify_determinism.lua        # digests for a spread of seeds
luajit tools/preview_map.lua 1337 > /tmp/m.json && python3 tools/render_map.py /tmp/m.json /tmp/m.png
```

`tools/render_map.py` is an offline sketch of the renderer (numpy + PIL). It is
not the game renderer, but its layer order, colours and sizing maths are the
spec the Defold one follows (it draws the real Noto glyphs, downloaded into a
gitignored cache), so it is the right place to try a visual change first —
`... /tmp/m.png detail` renders at 3x and crops the centre, roughly the game's
mid zoom. Pass a third argument to `preview_map.lua` to place that many
capitals with the real opening-state picker, so 🏰 can be judged with no game
running.

There is no automated check of the interface itself; it is verified by building
to the device and reading screenshots (`adb exec-out screencap -p > shot.png`).

`tools/make_textures.py` regenerates the parchment backdrop in `main/assets/`
(still named `nebula.png` — same mesh, same material), and
`tools/make_ui_textures.py` regenerates the interface atlas in
`main/assets/ui/` **and rewrites `main/ui.atlas`**. Re-run whichever applies
after changing a parameter; every PNG in those directories is a build artifact
of its script, not hand-authored art. Adding an interface glyph means adding a
function to the `ICONS` table and re-running — nothing to wire up by hand.

`tools/import_emoji.py` is an *import*, not a regeneration — the
`import_portraits.py` convention: it parses `main/theme.lua`'s `M.EMOJI` table
(the single source of what the map can draw), downloads those Noto glyphs at a
pinned release tag, packs `main/assets/emoji/sheet.png`, and generates
`main/emoji_sheet.lua` (UV rects — never hand-edited) plus provenance
(`MANIFEST.json`, `CREDITS.txt`, `NotoEmoji-LICENSE.txt`, Apache-2.0). Changing
which emoji the map uses means editing `theme.lua` and re-running it;
`test_wire.lua` fails if the resolver can name a glyph the sheet lacks.

### Android

The device build is bundled and installed straight from the CLI (`adb` lives at
`~/Library/Android/sdk/platform-tools/adb`, not on PATH):

```bash
JAVA=/Applications/Defold.app/Contents/Resources/packages/jdk-25+36/bin/java
$JAVA -jar ~/Defold/bob-1.13.1.jar --platform armv7-android --architectures arm64-android \
  --archive --bundle-output /tmp/android --variant debug --bundle-format apk build bundle
~/Library/Android/sdk/platform-tools/adb install -r /tmp/android/galaxy/galaxy.apk
```

Bob writes `debug.keystore` + `debug.keystore.pass.txt` into the project root on
the first debug bundle; both are gitignored build artifacts.

Useful on-device loop — `print` goes to logcat under the `defold` tag:

```bash
adb shell am force-stop com.dg.galaxy && adb logcat -c
adb shell monkey -p com.dg.galaxy -c android.intent.category.LAUNCHER 1
adb logcat -d | grep defold
adb exec-out screencap -p > shot.png       # verify visually
adb shell input swipe 800 1200 300 1000 400   # pan
adb shell input tap 907 2262                  # NEW GALAXY button
```

`adb shell input` covers taps and swipes, but **multi-touch cannot be injected**
— SELinux denies `sendevent` write access to `/dev/input/event7` even though the
shell user is in the `input` group. That is why gesture recognition is a
separate, testable module rather than inline in the camera script.

### Tests

No unit-test framework is configured. Two scripts carry the load, both exit non-zero on
failure and so work in CI as-is:

`tools/lint_shared.lua` is the first thing to run: it is the only check that
knows `galaxy/` has to satisfy two different Lua runtimes, and both of the
idioms it bans work perfectly under LuaJIT.

`tools/lint_globals.lua` catches the other class of thing no test can see: a read
of a global that should have been a local. It asks LuaJIT for a bytecode listing
and looks at the `GGET` opcodes, so it is exact rather than a regex guess, and it
ignores *writes* because a Defold script legitimately assigns `init`, `update`
and `on_input` as globals. It exists because `main/galaxy.script` passed a global
`seed` to `build_dust` from the first commit onwards: the file compiled,
`rng.stream(nil, …)` falls back to zero rather than erroring, and the dust
rendered - so the only symptom was that the starfield backdrop was byte-identical
for every galaxy in the game.

```bash
luajit tools/lint_globals.lua         # no stray global reads
sh tools/verify_cross_runtime.sh      # BitOp and arithmetic paths agree
luajit tools/verify_determinism.lua   # a seed reproduces exactly, across processes
luajit tools/test_sim.lua             # turn resolution, combat, fog of war
luajit tools/test_wire.lua            # client/server wire format round-trips
luajit tools/test_gestures.lua        # pan / pinch / tap recognition
luajit tools/test_playback.lua        # the past, rebuilt from the event log
luajit tools/test_plan.lua            # staged orders survive a send; a turn consumes them
luajit tools/test_territory.lua       # provinces tile, fuse, and rebuild identically
luajit tools/lint_shared.lua          # no idioms gopher-lua miscompiles
```

To check a *runtime* agrees with standalone LuaJIT, compare digests — the game
logs one at startup, and it must equal what `luajit` prints for the same seed.
Seed 424242 gives `3805718957` on macOS and standalone LuaJIT (re-baked when
the name generator was re-voiced for the atlas theme — names are hashed, so
touching `galaxy/names.lua` moves every seed's digest):

```bash
luajit -e 'package.path="./?.lua;"..package.path
  print(require("galaxy.digest").of(require("galaxy.generate").build(424242)))'
```

## Architecture

### Where things run

| | |
|---|---|
| `galaxy/` | Pure Lua generation. Runs on **both** the Defold client (LuaJIT) and the Nakama server (gopher-lua). No engine dependencies. |
| `main/` | Defold client: rendering, camera, HUD, backend client. |
| `server/modules/` | Nakama entry points. `docker-compose.yml` mounts `./galaxy` into Nakama's module path, so there is one generator, not two. |
| `tools/` | Offline harnesses and tests, run under `luajit`. |

### Simulation (`galaxy/sim/`, engine-free)

**The game is being rebuilt from the ground up.** What runs today is the
foundation, not a reduced version of something finished:

- every player has a **capital** and a single **captain**;
- captains move along the lane graph, and whatever they pass through becomes
  theirs;
- a captain with enough **strength** takes ground somebody else holds; one
  without it stops at the border;
- strength comes back only on ground you hold, fastest at your capital;
- holding enough regions wins; losing your capital loses, and being the last one
  with a capital also wins.

There is no production, no research and no buildings. Those were built once and
deliberately taken out, because the loop underneath them was never the thing
being tested. What is left to build back: **city upgrades producing unit types →
armies with a shape → a battle you can watch → the turn digest played back on
the map instead of listed.**

Combat was built back first, ahead of the production that will feed it, because
without it the game could not end. `tools/play.lua` proved it: the map was fully
carved by turn ~125 and then *nothing changed for 275 turns* - two players sat on
three of the four regions they needed and neither could take the fourth, because
a border was absolute. With strength, the same seed decides on turn 133 and the
borders move all the way through. **You cannot tune production until you know
what it buys.**

`resolve.turn(galaxy, state, orders)` advances exactly one turn and returns the
events it produced. It is a pure function of its inputs plus a per-turn seeded
RNG (`rng.stream(seed, "turn:" .. n)`), so a turn replays identically and a whole
game is reconstructable from `(seed, order history)`.

| module | role |
|---|---|
| `rules.lua` | every balance constant, so tuning never means reading logic |
| `systems.lua` | what kind of place a system is, derived from its star |
| `races.lua` | the six playable races, as pure modifier bundles |
| `modifiers.lua` | folds race into the numbers the resolver reads |
| `commanders.lua` | the named officer: rank, portrait, reach and what they lead |
| `units.lua` | the three things a colony can put aboard, and what each is for |
| `bots.lua` | what a bot does with its turn, on the server and in the harness |
| `state.lua` | opening state, captains, and JSON-round-trip repair |
| `path.lua` | Dijkstra along lanes; captains never move in straight lines |
| `regions.lua` | who holds a stretch of the galaxy, and who wins because of it |
| `resolve.lua` | the four phases of a turn |
| `view.lua` | fog of war: detection range, remembered state, per-player projection |

Turn order is **orders → movement → logistics → aftermath → visibility**. It was nine
phases; five of them belonged to production and went with it. Combat lives
inside movement rather than in a phase of its own, because it is what happens
when a captain tries to enter a system - not a separate step.

#### One captain, one verb

There is exactly one order:

```lua
{ kind = "move", captain = <id>, route = { <system>, ... } }
```

A route is a list of **waypoints**, expanded lane-by-lane by the pathfinder.
With two logins a day, standing orders are what make this playable rather than
tedious. Unclaimed systems are taken *in passing* and do not stop the captain,
so a route through a chain of empty systems sweeps them all up.

**A captain stops *before* a border, not on it.** Entering and then being
repelled would mean standing in a system you do not hold; the route is dropped
rather than held, so a captain never waits on something that may never change.

#### Whether you win is computed; what it costs is simulated

**Resistance has two halves, and both are public:**

```
fortification   the world's own, from its star + Bastion + capital
fleet           whoever is standing on it
```

**Two comparisons, and both must hold.** Your siege power against the walls,
your fleet power against the garrison. Beat both and you take it; fail either
and the captain stops at the border exactly as it did when there was one number,
with the event naming all four figures so the player can see which half turned
them back.

That is the arithmetic a player does *themselves*, on the sheet, before
committing a captain to a turn that resolves twelve hours later - which is why
combat has never needed a forecast, and the property unit types were designed
around rather than against. No dice: the per-turn RNG stream is still derived
and nothing rolls it.

**The exchanges then distribute the cost.** An *exchange* is a trade of damage
**inside a single turn** - the whole battle is over before the turn that started
it finishes and nobody else acts in between. It is not a turn, and the two words
must never be swapped.

Losses follow Lanchester's linear law: two forces grinding each other in
proportion leave the winner having lost `D*D/A`. That is not one formula among
several - it is **provably consistent with the comparison**, because `D*D/A < D
< A` whenever `A > D`. A player who did the arithmetic and was told they would
win, wins. A well-composed army also finishes in fewer exchanges and therefore
pays less, which is where composition earns its keep.

| | |
|---|---|
| `rules.defence` | `waypoint 2, outpost 5, colony 9`, plus `capital_defence 12` |
| `rules.captain_strength` | 6 at level one, `+1` a level - see below |
| `rules.exchange_depth` | how drawn-out an even fight is |
| `rules.shield_per_levels` | what a captain's own rank absorbs each exchange |

**An officer's own command is deliberately small.** It is never *spent* - a
battle takes units, and a captain with none loses nothing - so at 12 and `+3` a
level a level-four officer out-fought any colony on the map and could do it again
every turn, for ever, at no cost. Six and `+1` keeps a bare captain able to sweep
empty terrain, which is what early expansion is, while a colony at 9 needs
something aboard and a capital at 21 needs a real army.

**The captain's shield only ever reduces losses, never the outcome.** That is
what makes it safe to have at all: a veteran wins the same fights and comes out
of them stronger, without making the sheet's arithmetic a lie.

#### Three types, and an army is aimed rather than large

| | vs fortification | vs fleet | cost |
|---|---|---|---|
| **Line** | 1 | 1 | 20 |
| **Lance** | 1 | 3 | 34 |
| **Siege** | 3 | 1 | 34 |

Small integers on purpose: a player has to be able to add their hold up in their
head and compare it against two numbers on the sheet. Anything larger, or
fractional, and the whole design collapses back into needing a forecast.

**Line dies first**, which is what makes it worth buying - it is the only type
whose job is to still be there when the shooting stops.

**Composition is chosen at embarkation**, not fixed per colony. A colony holds
generic berths; the mix is picked when a captain loads, which is when the player
already knows what they are marching at. Fixing it per colony would be more
strategic on paper and miserable in practice: with three orders a turn, "my
Siege is nine lanes from the fortress" is a logistics puzzle rather than a
decision.

Two consequences worth keeping:

- **A capital needs a veteran.** `capital_defence` puts a capital above a fresh
  captain's entire ceiling, so eliminating a player takes an officer who has been
  winning - not an opening rush.
- **Strength does not come back on its own.** It is bought - see the economy
  below - which is what stops a deep raid running for ever and what makes the
  trip home mean something.

**A defeated captain is broken, not killed** (`commanders.demote`): thrown back
to its capital at zero strength and stripped of a rank. With one captain each, an
officer that could be removed from the board would end a player's game on a
single turn, and everyone would stop committing.

**Battles are the only source of experience**, worth the resistance overcome - so
a colony is worth more than a waypoint without any table having to say so.

**An empty batch is meaningful.** It is how a player says "I am done this turn",
which is what lets a turn resolve early once everyone has said it.

#### Three kinds of place

Every system carries a star class, a feature and a habitability flag, all public
map data. `systems.lua` turns those into three kinds of place:

| kind | derived from |
|---|---|
| **colony** | `habitable` |
| **outpost** | a productive feature or an energetic class |
| **waypoint** | everything else |

None of them currently produce anything - the distinction is what capitals are
placed on, what counts towards a region, **what it costs to take** (see
`systems.defence`), and what city upgrades will be priced against. `profile.industry` and `profile.science` are carried for the same
reason: they are derived from the star itself and cost nothing to keep.

**The generator guarantees a colony floor** (`config.colony_fraction`).
Habitability is a per-star roll and on a small map its variance decides the
game - the same setting produced 13 colonies on one seed and 26 on another. The
count is topped up deterministically, most habitable classes first with ties
broken by index, so every seed is fair while *which* worlds are habitable stays
driven by the roll.

#### The economy: one currency, and one thing it cannot buy

**Supply is fungible; units are not.** A system pays supply each turn, scaled by
the star's own `industry` — a number the generator has computed since it was
written and nothing read until now. Units accumulate *only* at colonies, up to
`colony_stock_cap`, and become strength *only* where a captain is standing. So
wealth alone never wins a front: it converts to force at a colony, and somebody
has to walk there.

| | pays | builds |
|---|---|---|
| waypoint | **nothing** | — |
| outpost | by `industry`, ~2 | — |
| colony | by `industry`, ~3 | only what it has dwellings for |
| a capital, on top | `rules.capital_yield` | |

**Road pays nothing, because the map had already decided that.**
`regions.lua:31` counts only colonies and outposts towards victory, so a
waypoint was already terrain for the purpose of *winning* and still wages for
the purpose of *paying*. Walking a captain down an empty chain was income for
the rest of the game, in a design whose whole point is that "systems owned" is a
poor measure. Colonies are towns, outposts are mines, the lane between them is
road.

It began as a pure redistribution — waypoints were 45% of the systems and 22%
of the income, and moving that onto the other two left whole-galaxy income
within a percent of where it was. **The sweep then took a third of it away**,
and the game got faster. See the pricing sweep below: every sink in this design
is capped, so income beyond what the sinks can absorb is not wealth, it is a
number going up.

**The capital's bonus is what makes the opening work.** With road paying
nothing, a player who has taken two systems and a stretch of lane earns almost
what they earned on turn one, and the capital is the only thing anyone is
guaranteed to hold. It is a shape rather than a decision — the generator places
the capital, so there is nothing to choose; the version with a choice in it is a
building that pays, and there is no room for one at four slots.

**A bot values ground at what it pays**, not from a table of its own:
`bots.lua`'s `score` calls `systems.yield` directly, so a bot follows the
economy automatically whenever it is retuned and there is no parallel ranking to
drift. It deliberately ignores the capital bonus — a bot cannot take a capital
and keep it paying, and pricing one as though it could would aim captains at the
target they are least able to hold. This had to land *with* the rate change:
until a bot knows road is worthless, every number `play.lua` produces is a bot
playing the old economy.

**Availability accumulates whether or not you visit, and does not decay.** A
distant colony is not wasted production - it is a reason to march. That is
lifted straight from Heroes of Might and Magic, along with the shape that makes
it a decision at all: **you have to pay for what is available.** Without the
cost, collecting is a chore rather than a choice, and you always take
everything.

#### The garrison: two complements, and only one of them is yours yet

A colony carries two, and they are not the same thing:

| | |
|---|---|
| `available` | what the dwellings have made and nobody has paid for, per type, to each dwelling's cap |
| `garrison` | what you bought. Sits here until a captain carries it away |

**Buying belongs to the colony, not to a captain.** What is bought goes into the
garrison and waits, so a player spends the turn they have the money and collects
whenever somebody can get there. Before this, arming needed an officer standing
on the spot at the moment of purchase - which with three dwellings in three
places is three tours to synchronise with a purse.

**Buying and transferring cost no order** (`rules.order_cost`). An order is
something that *happens somewhere*: moving a captain, raising a building,
raising an officer. Buying is spending, and a transfer is a captain rearranging
what is already yours at a place it is already standing. Charging for a purchase
was right while one went straight into a hold; it stopped being right the moment
purchases went into the colony, because charging an empire act means a rich
player banks supply they cannot convert - which is precisely the failure
buildings were introduced to fix, one level down.

**A transfer carries a target hold, not a delta.** Whatever the captain should
have aboard when the turn is over; the resolver works out which way each type
moves. A delta would be wrong the moment anything else touched either side first
- a purchase landing the same turn, a battle on the way in - and this way the
client only ever states the thing the player chose. Buying settles before
transferring, so a purchase and a collection are one turn's work.

**The garrison defends**, folding into the `fleet` half of the two comparisons
that already exist rather than adding a concept. Production used to defend the
world holding it and had to be taken out, because defence accumulated for free
while an attacker carried theirs across the galaxy. A garrison is not that: it
is bought, so every unit standing on a world is a unit not in a captain's hold
and the trade pays for itself.

**But being bought was not enough, and that is why there is a cap.**
`rules.garrison_cap` exists because the two sides are not symmetrical: an
attacker's power is bounded by `captain_units` - no amount of wealth brings more
than a hold - while a defender's was bounded by nothing. Measured, uncapped:
**three seeds in ten never decided at all**, territory bit-identical from turn
800 to 900, two players sitting on three of the four regions they needed. The
same freeze combat was built to end, wearing a receipt. Capped at what one
captain carries, all ten decide again.

**What was ready scatters; what was built stands.** A colony that changed hands
handing its conqueror an instant army would pay for taking it twice over, so
`available` is emptied and the garrison dies in the fight that took the world.
The dwellings do not: they are the prize.

#### Pricing it: `tools/sweep.lua`

One variant per process, because the modules are cached and mutating `rules` in
place leaks into every later run in the same VM. Overrides are assignments -
`rules.garrison_cap=8`, `foundry.every=2`, `rules.supply_yield.colony=3` - and
what it reports is deliberately more than how long a game takes:

    decided 20/20  median 125  range 71-191  first fight 30  idle 415  built 122
    raised: berths 767  interceptor_bay 675  foundry 585  bastion 325  admiralty 103

**`idle` is the number that found everything.** It is the supply a surviving
player is still holding when the game ends, and at the shipped prices it was
**8,316** - fifty turns of income nobody could spend. Every sink here is capped
(four slots, six in a garrison, two of a type ready), so past a point the
economy simply stopped being a decision.

What the sweep established, in order:

- **Money was never the constraint; throughput was.** Halving every dwelling
  price moved the median the *wrong* way (181 → 167) and pushed idle supply to
  8,800. Raising the stockpile cap did nothing either. Only the cadence moved
  it: `every = 1` on all three took the median to 128 and idle to 2,500.
- **That reverses an older rule** which said every-turn production never
  decides. True of a pooled stock every colony got free; not true once
  production is gated behind a building bought with an order and a slot.
- **Then income came down 38%**, and the game got *faster* again — 125, with
  idle at 415. Money running out is what keeps the economy a decision all game.
- **Two prices I expected to be wrong were not.** The Admiralty is reachable —
  players finish with a median of two to three captains against a ceiling of
  four — and Bastion gets built. Doubling `bastion_defence` made games *slower*
  and left more supply idle, so 8 is not a placeholder.
- **The four-slot cap does bind.** Five slots is ~9 turns faster with less idle
  supply. Keeping four is a deliberate cost, now a measured one.
- **The captain ceiling earns its place.** Capping at two rather than four cost
  9 turns and doubled idle supply — parallel officers are how an empire spends.

Twenty seeds, every player count, before the sweep and after:

| | 2p | 3p | 4p | 6p |
|---|---|---|---|---|
| before | 93 | 127 | 181 | 217 |
| **after** | **92** | **129** | **125** | **170** |
| idle before | 1313 | 4133 | 8316 | 6308 |
| **idle after** | **213** | **308** | **415** | **602** |

All twenty decide at every count. That also closes a listed gap: six-player
games used to need 400–1000 turns and sometimes never got there.

**Rank sets where a captain starts, not what they can carry.** `base_strength`
is the officer's own command and where a broken one reforms; `max_units` is what
they can lead on top of it, and it is generous. Capping the *total* at the rank
base walled the game shut - a fresh captain could not cover a defended colony,
so could never win the battle that would have promoted them, so never got any
stronger. Every game froze with two players on three of the four regions they
needed and full purses they could not spend.

**Stock deliberately does not defend the colony holding it.** It did, and it
nearly doubled what a colony cost to take, which re-froze the map that combat
had just unfrozen: defence accumulated for free while an attacker had to carry
theirs across the galaxy. Fortifying will be a choice a player makes, not
something that happens to a world nobody visited.

**A captain buys where it *ends* the turn**, so a march onto one of your own
colonies and an embarkation there are one turn's work. The RPC supersedes per
*kind* for that reason - a resupply that superseded the march would leave the
captain buying where it already stood.

The numbers were measured, not guessed (`tools/play.lua`):

| | median 4-player game |
|---|---|
| stock cap 4, every 2 turns | 283 turns |
| **stock cap 6, every 2 turns** | **190 turns** |
| stock cap 4 or 6, *every* turn | never decides |

Making stock accrue every turn is worse than either: a front where both sides
refit as fast as they can spend never moves.

#### Buildings: four slots, five things, and they do not stack

A colony **specialises**, so the decision is spatial rather than numeric: this
one makes escorts, that one is where officers come from, the one on the frontier
is a fortress. You give up exactly one, and where the colony sits decides which.

| | | |
|---|---|---|
| **Berths** | 60 | Escorts accumulate here |
| **Interceptor Bay** | 140 | Interceptors accumulate here |
| **Foundry** | 160 | Bombards accumulate here |
| **Bastion** | 100 | flat resistance, and arms nobody |
| **Admiralty** | 220 | another captain allowed, and the place to raise them |

**A colony makes only what it has dwellings for.** There is no base production:
a world you have just taken pays supply, counts towards its region and is
somewhere to stand, but has no shipyard until you put one there. That is what
makes the four slots the whole decision rather than a bonus on top of one — and
because **buildings live on the system**, a colony changes hands with everything
built on it. Somebody else's developed arsenal is a target worth marching on,
which is the first time the map has had a reason to want a *particular* world
that was not a region tick or a capital.

**A capital opens with Berths standing.** A player who cannot arm at all until
they have saved the price of a dwelling has no opening — they watch a number
climb for several turns and do nothing.

Slots went from two to four with the dwellings: two was right when a building
was a multiplier on production that happened anyway, and would have meant a
colony could make one thing *or* be anything else.

**Buildings need no captain present.** Raising one is an empire's decision, not
an errand, and requiring an officer to stand there would make the whole economy
hostage to one captain's touring speed. It is also the sink that absorbs a large
empire's surplus, which units alone never could - colonies produce at a fixed
rate however rich you are, so before buildings a hundred-system empire banked
tens of thousands it could not spend.

**A Bastion is the only way a world gets harder to take.** Production used to
defend the colony holding it, which meant a world nobody had visited fortified
itself for free; fortifying is now something a player chooses and pays for.

**Captains: one, plus one per Admiralty, to a ceiling of four.** The ceiling is a
rule rather than a layout accident - the commander strip is a row of faces, not
a list, and stops being readable past four. A second captain is the answer to the
touring problem: parallel collection, parallel fronts.

Buildings and recruitment settle in the **logistics** phase, after movement, so a
colony taken this turn can be built on this turn - and a build on a colony *lost*
this turn is refused rather than quietly enriching whoever took it.

#### Capitals

`pick_capitals` places every player on a colony with at least
`rules.capital_neighbours` more within `rules.capital_hops` lanes, then spreads
them by farthest-point sampling. A player who spawns in a barren arm, or next
door to a rival, has lost at generation rather than in play.

A capital is currently only a spawn and a losing condition - **hold it or you
are out** - and is the one place a player will build once upgrades exist.

#### Captains

A captain is a named officer with a rank, a face and a speed. The name and the
portrait are most of the point: a piece a player is attached to is worth more
than a token. Everything derives from `level`, so state carries only a level and
an experience total.

**Battles award experience**, worth the resistance overcome. Rank buys reach
*and* weight, so a veteran covers more lanes a turn and can crack a capital a
fresh officer cannot.

**Movement is whole lanes, not a distance.** A captain crosses
`rules.captain_steps` lanes a turn and always ends the turn *at* a system.

It used to be a speed - 95 world units a turn along lanes varying from roughly
60 to 200 - and the problem was not the arithmetic but that **the number the
rule depended on was invisible.** Lane length is never drawn, never stated and
cannot be eyeballed, so "when does Kess arrive?" had no answer a player could
work out, in a game whose whole point is planning two logins ahead. A step is
countable off the map: a four-lane route takes four turns.

What this gives up is that lane *length* stops meaning anything - a 200-unit
lane and a 60-unit one are the same move. If that is missed, the way back is to
price some lanes at two steps and draw them as such, not to return to a
continuous speed nobody can see.

**Rank buys reach rather than pace** (`rules.steps_at_rank`): a Commodore covers
two lanes a turn, a Grand Admiral three, and a race with a mobility bonus adds a
whole extra one. Fractions of a step would be exactly the invisible arithmetic
this replaced.

**The pathfinder counts lanes too.** It used to minimise distance, which after
this change could return a route one lane longer - and therefore a turn slower -
than the alternative. Length survives only as a tiebreak between routes of equal
length, so the tighter-looking one wins.

#### Detection is a range

Each *source* sees a distance of its own: a system you hold reaches
`base + race`, a captain barely past itself. The visible set is the union,
computed as a relaxation rather than a plain breadth-first walk, because the
widest source has to win wherever two overlap.

**Rival captains are visible where you have eyes.** Their rank and heading show;
their orders do not.

#### Bots

`galaxy/sim/bots.lua` is engine-free like the rest of the simulation, so the
same code decides a bot's move on Nakama and in `tools/play.lua` under luajit.
**One implementation on purpose**: an AI that only existed in the harness would
be the one nobody plays against, and the one that shipped would be the one
nobody tests.

- **Deterministic.** A bot never touches `math.random`; its stream is
  `rng.stream(seed, "bot:" .. player .. ":turn:" .. n)`, so replaying a game
  reproduces the bots exactly and a Nakama restart does not change a decision
  it had already effectively made.
- **Decided at resolution, not submitted.** Bots have no storage record and
  never write orders; `catch_up` asks them for a batch just before
  `resolve.turn`. The resolver cannot tell them from a human, which is the
  point.
- **Always ready.** `everyone_submitted` ignores bots, so a solo game against
  three of them resolves the instant the human ends their turn. That is most of
  what having them is for.
- **They never walk into a border.** The search only travels through ground the
  bot already holds, because a captain turned back has wasted the trip.

It is a plain function rather than a behaviour tree. The game has one verb, so
the whole decision is "which system next", and a tree there is ceremony around
an `if`. When a bot has to weigh expanding against defending against raiding
against building, that is the moment to reach for one - and to vet it against
the gopher-lua traps first.

#### Regions are the objective

The map is deliberately far bigger than any one player will touch. With one
captain each and two hundred systems, most of the galaxy is scenery - and that
is the intent. What it means is that "systems owned" is a poor objective: it
counts the empty road a captain walked down alongside the world they fought for.

So the unit of contest is the **region** the generator already carves: a named,
contiguous stretch of a dozen or so systems, of which only the colonies and
outposts count. A player holds a region by holding **more than half** of what is
worth holding in it, and the game is won by holding
`rules.victory_region_fraction` of all regions.

Nothing about control is stored. It is a pure function of who owns what, so it
is recomputed rather than tracked.

#### Pacing

`tools/play.lua` plays a full game with a captain-per-player AI that walks at the
nearest unowned system. On the default map four players carve it up and one wins
around turn 130 - about two months at two turns a day. That is a skeleton
pacing, not a tuned one: with nothing to build and nothing to fight with, the
only thing a player can do is walk.

It is also where the losing-player problem is already visible: an AI boxed in
early finishes with a tenth of the map and no way back.


### The game (server-authoritative, asynchronous)

2-10 players compete for the galaxy. Turns resolve on a schedule, players issue
orders between them, and the map is public while state is fogged.

RPCs in `server/modules/game_rpc.lua`:

One order became four. `game.orders` takes `move`, `resupply`, `build` and
`recruit`; a captain may carry one move and one resupply in a turn, and a colony
one build. A `resupply` carries a **mix**, not a count - and both the RPC's
cleaning pass and `catch_up`'s rebuild put it through `units.normalise`, because
this is the third time a widened order shape has been silently flattened by a
`tonumber` in one of those two places.

**A turn is worth only `rules.orders_per_turn` of them.** Not a safety limit - a
scarcity. With four captains and a dozen colonies there is always more worth
doing than three orders allow, so a turn is a choice about what matters most
rather than a round of housekeeping.

It works at three because **a route is a standing order**: a captain given
somewhere to go keeps going, for as many turns as it takes, at no further cost.
An order is what it costs to *change* a plan, not to maintain one.

Three things make it a decision rather than a wall:

- **Revising is free.** Superseding runs before the budget, so re-routing a
  captain or changing which building a colony gets costs nothing extra - it is
  the same decision, changed.
- **An order can be taken back** before it is sent (`store.plan_remove`, and the
  `x` beside each line in the order bar). Taking one back is as much a decision
  as making one when a turn only holds a few.
- **The count is stated, not implied.** The bar reads "1 of 3 orders used"; a
  budget the player has to work out for themselves is not one they can spend.

`rules.order_cost` is a table rather than a rule buried in the resolver, so
making a kind free is one edit. Resupply is deliberately not free: a captain
that could always top up for nothing would always top up, and collecting would
be a chore rather than a decision again.

**Bots are held to the same allowance** (`bots.all_orders` trims to it). An AI
that got five decisions a turn to a player's three is not a difficulty setting,
it is a different game. It also tightened pacing rather than hurting it - the
four-player spread went from 94-315 turns to 85-174.

| rpc | purpose |
|---|---|
| `game.create` | new lobby; rolls a seed, sets turn interval, size and the creator's race |
| `game.list` | open lobbies, **and separately** the caller's own games |
| `game.join` / `game.start` | lobby management; `join` carries the race pick |
| `game.state` | the caller's fogged view plus events since a given turn |
| `game.route` | what path an order would take, for the client to draw |
| `game.orders` | submit (and freely revise) orders for the coming turn |

There is one order, and `game.orders` replaces the whole batch:

```lua
{ kind = "move", captain, route }
```

The RPC checks *shape* only, and supersedes rather than appends: a second order
for the same captain replaces the first, so the array's position never carries
meaning a client would have to know about. Whether an order is *legal* depends
on state that will have moved on by the time it resolves, so the resolver
decides that and emits an `order_rejected` event carrying a reason the client
can show.

**A turn resolves as soon as every player has submitted**, and otherwise on the
clock. Submitting is what ends a player's turn, so once the last one is in there
is nothing left to wait for - and waiting out a twelve-hour timer anyway is the
worst thing an asynchronous game can do to four people who are all paying
attention at the same time. An empty batch is how a player with nothing to do
says they are done, which is what makes this reachable at all.

Two details keep it honest: `early` unlocks only the *first* turn of a call, so
once it resolves nobody has submitted for the next one and the loop falls back
to the clock; and an early resolution restarts the clock from *now*, or four
prompt players would find the next turn already half over.

**Otherwise turns resolve lazily.** There is no scheduler: every RPC first asks
whether turns are due and resolves however many were missed. That needs neither
cron nor Nakama's Go runtime and cannot drift. The consequence is that an
untouched game does not advance until somebody touches it. Concurrent resolution
is prevented by version-guarded storage writes - the loser of the race discards
its work and re-reads.

Storage layout (Nakama storage; the Lua runtime has **no SQL access**):

```
games      / <id>          system-owned   lobby, schedule, roster
game_state / <id>          system-owned   the simulation state
game_events/ <id>:<turn>   system-owned   one turn's events
game_orders/ <id>:<turn>   per-user       that player's orders
```

Everything is system-owned except orders, so a player cannot read another
player's pending moves straight from storage.

**Sim state is repaired on read** (`state.normalise`). It round-trips as JSON,
and while dense arrays survive, `knowledge[player]` is keyed by star id and
*sparse*, so it returns with string keys. Indexing it with a number would then
silently miss and every player's fog memory would look empty after each turn.

**The repair has to match the shape it is repairing.** This one coerced each
entry with `tonumber(entry) or 0`, which was correct when memory was `id -> turn`
and quietly flattened every record to the number zero once `view.remember`
started storing `{ turn, owner, capital_of }`. The function written to *stop* fog
memory being wiped on every read was the thing wiping it, and `view.project`
crashed outright the first time a player remembered somewhere they could no
longer see. Nothing offline caught it: under LuaJIT the crash needs a remembered
system that is not also currently visible, which the tests happened not to
produce. It was found by playing a game through the real RPCs.

For the same reason `view.project` keys systems by **string** id: a Lua table
with sparse integer keys encodes ambiguously, and the client must be able to
tell which system each entry describes.

### Backend (Nakama)

```bash
docker compose up -d          # postgres + nakama
docker compose logs -f nakama
docker compose down
```

Console at http://127.0.0.1:7351 (`admin` / `password`), client API on 7350.

The client authenticates with a random per-install device id (`main/device_id.lua`,
persisted via `sys.save`) and calls the `galaxy.get` RPC, which returns the map
in the wire format defined by `galaxy/wire.lua` — a contract shared by both
sides, so there is no encoder/decoder pair to drift. Only what cannot be derived
is transmitted (~40 KB); colours, labels, adjacency, borders and bounds are
recomputed on arrival from the same tables the generator used.

Set `galaxy.use_server = 0` in game.project to run fully offline, or
`galaxy.nakama_debug = 1` to trace requests — note that prints the session
token, so leave it off otherwise.

**Testing against a physical device**: the phone's `127.0.0.1` is the phone, so
forward the port over USB rather than changing the host:

```bash
adb reverse tcp:7350 tcp:7350
```

**Server-side generation is slow — 4-6 s for an uncached seed**, then instant
(results are memoised per seed, per runtime VM). That is the cost of running a
numeric workload on gopher-lua, an AST-walking interpreter: the same code takes
~50 ms on LuaJIT. Most of it is Poisson sampling. If this needs to be fast, the
options are precomputing seeds, moving generation to a fast sidecar the RPC
calls, or Nakama's Go runtime — not micro-optimising the Lua further.

### Five things that will bite you on the Nakama runtime

Nakama's Lua is gopher-lua, not LuaJIT, and differs in ways that fail *silently*:

1. **`a, b = b, a` is miscompiled.** The multiple-assignment swap is evaluated
   sequentially, so both names end up with the second value. This turned every
   reordered edge in `delaunay.edges` into a self-loop — a third of the lane
   graph — while the client was perfectly fine. `tools/lint_shared.lua` fails
   the build if the idiom reappears in `galaxy/`. Use an explicit temporary.
2. **There is no `bit` library.** `galaxy/rng.lua` detects this and falls back to
   an arithmetic implementation that produces bit-identical results. Without it
   the generator cannot load at all.
3. **`rpc_func`, not `rpc_func2`.** The latter sends the payload as a `?payload=`
   query parameter, which Nakama 3.27 delivers to the RPC as an empty string.
   The server then defaults the seed and serves the same galaxy every time.
4. **Nakama images before 3.27 are amd64-only** and run under emulation on Apple
   Silicon — ~5x slower again, and it was OOM-killed mid-generation. 3.27+ is
   multi-arch.
5. **`goto` and labels are Lua 5.2.** LuaJIT accepts them happily, so a
   `goto continue` passes every offline test in `tools/` and is a coin flip on a
   5.1 runtime. Nothing in the test suite could catch it — the editor's language
   server, also configured for 5.1, was what reported it. `lint_shared.lua` now
   fails on `goto` and on `::label::` in `galaxy/` for the same reason it fails
   on the swap idiom: the hazard is that it *works* locally.

`collectgarbage("count")` also returns nil under Nakama's sandbox, so it is
useless for diagnosing memory there.

### Determinism

Still required, though not for the reason it first appears. Since the server
ships the whole map, the client does not need to *reproduce* it — but the server
must agree with itself, so that a seed survives a restart, a second server
instance, or a player rejoining. The client generator staying in step is what
makes the offline fallback safe rather than a divergence.

The non-obvious choices behind it:

- **`rng.lua` implements SplitMix32**, not `math.random` (implementation-defined
  and globally stateful). It uses only BitOp calls and exact sub-2^53 double
  arithmetic, so it produces identical values on every Defold target. 32x32-bit
  multiplication is done by 16-bit splitting because the full product overflows
  a double's exact range.
- **`rng.stream(seed, label)`** gives each subsystem its own derived stream, so
  adding or reordering a subsystem cannot shift the numbers every *other*
  subsystem sees.
- **Never iterate a hash table with `pairs` where the order affects output.**
  Lua's `pairs` order is unspecified. Anywhere a set has to become a sequence
  (`graph.region_adjacency`, `tools/dump.lua`), the keys are sorted first.
- **Seeds must stay below 2^24.** `go.property` numbers are 32-bit floats, so
  larger integers do not round-trip — 20260823 comes back as 20260824.
  `galaxy.script` floors and wraps the incoming property for this reason.
- **The density field is quantised to a 16-bit ladder** after being built from
  `exp`/`log`/`atan2`. Unlike `sqrt`, those are not required to be correctly
  rounded, and glibc, macOS libm and Android's bionic can disagree in the last
  bit — enough to flip one accept/reject in sampling and cascade into a
  different galaxy. Snapping to a coarse ladder makes that unreachable.

### Rendering (`main/`)

**The map is a hand-drawn atlas**: warm parchment, dotted ink paths, and every
system drawn as a Google Noto color emoji whose *meaning* says what the place
is — 🏰 a capital, 🏙 a colony, ⛏/🛰/🏛/🌀/💫-class glyphs for what makes an
outpost worth holding, ✨ bare terrain. `main/theme.lua` is the one resolver
from system to glyph name (the game, `tools/render_map.py` and `tools/test_wire.lua`
all go through it, so the wire and the offline fallback cannot disagree);
`main/emoji_sheet.lua` (generated) maps names to UV rects in
`main/assets/emoji/sheet.png` (imported — see the tooling section). A new look
is tried in `tools/render_map.py` first; its constants mirror the engine's
(`CORE_SCALE × KIND_SCALE × (0.85 + 0.3r)`), so an approved sketch transfers 1:1.

Seven mesh components, one per layer, each with a dynamic vertex buffer built
once per seed by `main/meshbuild.lua` and uploaded with `resource.set_buffer`.
Per-item colour lives in a **vertex stream**, not a material constant — a
per-component constant would break batching, so this keeps each layer to a
single draw call. The whole map is ~7 draw calls and does no per-frame CPU work
except the parallax backdrop.

**Shapes are still drawn procedurally in the fragment shaders wherever they are
shapes.** A textured quad is only ever as sharp as its texture, so discs, dots
and falloffs derive from the UV and antialias against `fwidth`. The emoji are
the deliberate exception — a glyph is art, not a shape — and the sheet is sized
so it never betrays that: 256px cells that never magnify past ~70% at
`ZOOM_MAX`, 16px gutters with 8px UV insets so linear sampling and mips never
bleed a neighbour, and **mipmaps via `galaxy.texture_profiles`** (the emoji
directory is the only override; everything else keeps the no-mip default),
because ~220 glyphs minified at the widest zoom shimmer on every pan without
them. `.mesh`/`.material`/`.fp`/`game.project`/texture-profile/PNG changes all
need a full build — only `.script`/`.lua` hot-reload.

| shader | used by | what |
|---|---|---|
| `emoji.fp` | systems | glyphs from the sheet; vertex colour is white × fog alpha, never a tint |
| `disc.fp` | lane dots + province borders | hard disc, edge antialiased with `fwidth` |
| `shadow.fp` | drop shadows | soft dark disc under each glyph, offset down-right |
| `dot.fp` | paper flecks | soft point |
| `wash.fp` | territory fill / region blobs | flat across province fans, soft falloff on blobs |
| `mesh.fp` | parchment mottle | the textured backdrop quad |

**Territory is a political map** (`main/territory.lua`, engine-free,
`tools/test_territory.lua`): every owned system's Voronoi cell — the dual of
the Delaunay triangulation the lanes already come from — fused per owner into
provinces that tile and never overlap, exactly like countries on an atlas. The
fill is the cell polygons fan-filled flat on the wash layer in the *bright*
player palette (a stain wants saturation; ink is for pen work), reaching
exactly to the border; the border is a thin solid pen line along cell edges
where the neighbour's owner differs, inset slightly into its own ground so two
rivals meeting draw two hugging lines. Interior edges between same-owner cells
vanish, which is what fuses cells into one province. Every Voronoi edge is
jittered by midpoint displacement keyed on the pair of systems it separates,
so both sides bend identically and the tiling holds — organic, deterministic,
no RNG stream. Hull cells close with an arc capped at `TERRITORY_CAP`. A
player who holds nothing is a **zero-vertex buffer, which is a native crash**,
not an empty mesh — `build_wash` emits one invisible triangle instead.
Browsing a seed (no view) falls back to soft region blobs.

**Lanes are dots along a bow, not ribbons.** Each dot is its own quad through
`disc.fp`; the bow is a quadratic bezier whose bulge is a pure function of the
lane's endpoint indices (no RNG stream, same formula in the sketch), capped at
7% of the lane because captains, route previews and playback markers travel the
*straight* line — a marker must never sit visibly off its own path. The dot
count varies per lane, so `build_lanes` collects positions first and sizes the
buffer second: `Builder:apply` demands the buffer be filled exactly. The same
layer carries the province border strokes ("solid" is discs overlapped tighter
than their radius), which is why `repaint` rebuilds lanes alongside wash and
owners: borders follow a playback's rewound owners. `build_wash` runs first in
both `present()` and `repaint()` and caches the cells for `build_lanes` — that
ordering is the cache's contract.

Two consequences worth knowing when tuning: `build_stars` captures
`knowledge()`'s first return into a local before building the quad —
its two-value return expands into argument lists, and an expanded `owner` would
land in `u0`; and the two player palettes in `galaxy/config.lua` are twins by
index — `player_palette` (bright, for the dark chrome) and `player_palette_ink`
(dark, for everything drawn on the paper) — same hue, same order, and the
digest hashes structure rather than RGB, so retuning a tone is free while
reordering is not.

**A rebuild of the same galaxy must not disturb the view.** `present()` in
`main/galaxy.script` builds every mesh, and it runs whenever a turn resolves
because the fog and ownership the meshes encode have changed. It posts
`map_ready` to the camera, and the camera used to treat *every* `map_ready` as a
new galaxy: reset zoom to the whole-map fit, clear `user_zoomed`, recentre. With
a background poll every ten seconds, the effect was the player's zoom silently
resetting itself every ten seconds, and the selected system deselecting with it.

Two guards now, because either alone would leave the trap set for the next
caller:

- the camera re-frames only when the content extent or centre differs from what
  it has, or when it has never framed anything (`self.framed`);
- `present()` clears the selection only for a genuinely different seed, and
  `load_game` skips the rebuild entirely when neither the seed nor the turn has
  changed — about 30 ms of work saved every poll, for no visible difference.

### Zoom and the backdrop

**Zoom is three buttons on the right of the map**, under the overview:
in, out, and out-to-the-widest. Before them there was no way to zoom at
all - pinch is the only other route and multi-touch cannot be injected from a
workstation, so every device screenshot ever taken was at the fit zoom.

**The whole-map view is deliberately unreachable.** `ZOOM_OUT_LIMIT` in
`main/camera.script` holds the zoom floor at twice the whole-map fit: the map
is mostly scenery, the widest useful view is a stretch of regions, and the
floor is also what keeps the smallest-ever emoji glyph legible. Three things
changed with it, all in the camera or `present()`:

- the widest-view button keeps the player's centre instead of gliding to the
  galaxy's - recentring on the middle of a map you cannot fully see carries
  you away from your own empire - and it now *sets* `user_zoomed`, because
  the result is still a view the player chose;
- opening a game focuses your capital once (`present()` posts `focus` for a
  new seed when the view knows one), since the opening frame can no longer
  show everything;
- a playback still ends on the widest view for an arrival digest, which is now
  "as wide as allowed" rather than the poster.

They are on the *top* right, which costs some thumb reach, because the bottom
right is not a stable place to put anything: the order bar spans the full width
and grows upward as the plan does, and the system sheet comes up over it. A
control that moves when you stage an order is the problem SEND was kept still
to avoid.

Three details, each of which the first run of the buttons found:

- **`ZOOM_MAX` is 3.0.** It was 9.0, and nothing had ever been there. 9.0 is 80
  world units across and lanes run 60 to 200, so the whole screen sits *between*
  two systems - a bare lane, no star. 3.0 is a system and the ones it is joined
  to, which is as close as there is anything to see - and it is also the number
  the emoji sheet's cell size was chosen against.
- **A button zoom pivots on the selected system**, if there is one and it is
  somewhere visible; otherwise on the middle of `store.hud_band`. Never the
  middle of the *window*: with a tall sheet up that point is behind a panel, and
  pivoting on something invisible sends everything the player can see rushing
  off the top of the band. Anchoring on the selection is what stops the star
  sliding off the pivot and ending up behind the sheet describing it - three
  presses was enough.
- **The camera eases rather than jumps**, for the same reason `focus` does, and
  a press steps from the *target* rather than the current zoom so an impatient
  double-tap adds up instead of landing mid-glide.

The camera owns the step size and the range; the buttons only say which
direction, so there is one description of how far a press goes.

**The backdrop texture carries only the mottle; the paper is the clear
colour.** `tools/make_textures.py` writes `main/assets/nebula.png` (the name
survives the re-theme - same mesh, same material) as a parchment-tinted stain
whose alpha is its strength, over a clear colour that IS the parchment base -
set in `game.project [render]` and mirrored as the render script's fallback.
The old close-zoom fade (`main/galaxy.script`, zoom 0.6 to 2.2, driven through
the `tint` USER constant via `go.set`) was kept untouched, because what it now
does is fade the mottle to clean flat paper as a fixed-resolution stain would
otherwise smear - the right behaviour, inherited for free. The wash still eases
back to 45% with it.

`main/render/galaxy.render_script` owns the layer order and blend modes.
Everything blends with alpha - on paper there is no light to add, so the old
additive dust/glow entries emptied out of the `ADDITIVE` table (kept, one line
to give a future layer back):

    nebula   wash   lanes   glow(shadows)   owners   stars   gui - all alpha

Textures are premultiplied by Defold at build time, so alpha layers use
`ONE / ONE_MINUS_SRC_ALPHA` (not `SRC_ALPHA / ...`) and the shader premultiplies
the vertex colour to match.

### Setting up a game

Creating and joining are their own flow (`main/screens/setup.*`), not part of
the lobby. The race picker used to sit at the top of the lobby - the largest,
first thing on screen, and inert until you were actually creating or joining
something. **A choice belongs where it is being made.**

One screen does both jobs, because they ask the same question: creating picks
your race and fills the other seats with bots, joining picks your race and shows
you who is already there. The lobby is now a list of games and one button.

**A player must be able to end a turn with nothing to say.** Submitting is what
ends a turn and the game resolves once everyone has, so the order bar reads
`END TURN` when nothing is staged rather than a dead `NO ORDERS`. Without it the
early-resolution path was unreachable by a human - the client had no way to send
the empty batch the server was waiting for.

### Leaving a game

A menu glyph sits top right of the overview bar, where EMPIRE used to, and opens
a confirmation. The map had no exit at all before it: once you were in a game
the only way back to the lobby was to restart the app.

The confirmation says two true things - the game is still there when you come
back, and, **when there are staged orders that have not been sent, that leaving
loses them.** Those orders live in `store` and nowhere else, so that is a real
consequence and the reason the dialog exists rather than an immediate exit.

Two traps, both found by trying it:

- **`monarch.back()`, not `monarch.show(hash("lobby"))`.** The lobby is already
  underneath the map on Monarch's stack, so showing it again does nothing and
  leaves the map loaded - running, with its game pulled out from under it.
- **A popup cannot navigate from its own callback.** Monarch is tearing the
  script down as the callback runs, and a `monarch.back` scheduled from there
  silently never happens. The menu sets `store.leave_requested` and the HUD acts
  on it, because the HUD is still alive at that moment.

The store is cleared *after* the map has gone. Wiping it while the map was still
running left it rendering a game it no longer had - a map with no owner,
offering a new galaxy.

### Client screens (Monarch) and UI (Druid)

`main/main.collection` is a bootstrap holding `main/app.script` plus one Monarch
screen proxy per screen. **The empire screen was removed** in the rebuild: with
no production and no research there was nothing on it the map does not already
show, and the captain strip is the roster. The proxies are **embedded instances** with their
`screen_id` set inline, matching Monarch's own example — a `screen_id` override
placed in a separate `.go` file did not take effect, and every screen silently
registered under Monarch's default id (`UNIQUE ID HERE`), so `monarch.show`
found nothing.

| screen | collection | role |
|---|---|---|
| `lobby` | `main/screens/lobby.collection` | list/create/join/start games |
| `map` | `main/screens/map.collection` | the galaxy view (was the old bootstrap) |
| `report` | `main/screens/report.collection` | turn digest; a **popup** over the map |
| `slot` | `main/screens/slot.collection` | one upgrade slot; a **popup** over the map |
| `transfer` | `main/screens/transfer.collection` | a colony's garrison and the captain on it; a **popup** |

**The map screen sets `screen_keeps_input_focus_when_below_popup`.** Monarch
defaults that to *false*, so showing a popup posts `release_input_focus` to the
screen underneath — and the matching acquire on hide did not reach the HUD, which
came back from the empire screen unable to receive a single touch. The symptom is
brutal to read: nothing errors, nothing looks wrong, the buttons simply stop
working. Popups here are modal anyway (`ui.modal_input` returns true
unconditionally), so the screen below never needed its focus taken away in the
first place. The property is set inline on the map's embedded proxy instance in
`main/main.collection`, next to `screen_id`.

`app.script` authenticates once and then shows the lobby, so moving between
screens never re-authenticates. Screens are handed their parameters through
Monarch (`monarch.data`), which is how the map learns which game to load.

Screens are built in code rather than laid out in `.gui` files (`main/ui.lua`
holds the shared look). Their content is dynamic — a list of games, a list of
turn events, a research tree — so most of it would be script-created anyway.

### The plan

Choices are **staged in `store`, not sent** — `store.orders` holds
movement orders in the exact shape the RPC takes. They travel with the next SEND, which is what
keeps the one-batch-replaces-everything rule above safe and lets the player
revise the whole turn freely until it resolves.

**Sending does not clear the plan.** `game.orders` *replaces* the batch the
server holds rather than appending to it, and the client used to empty
`store.orders` the moment a send succeeded — so the sequence any player actually
performs (send an order, notice another one, send again) shipped a second batch
containing only the new order and the server threw the first one away. Nothing
errored and the button said SEND both times. The plan now lives until the turn it
was aimed at resolves, and **every send transmits all of it**. `store.plan_*` owns
that lifecycle:

| | |
|---|---|
| `plan_signature()` | a stable string for the batch; compared against `sent_signature` to answer "is anything unsent?" — more reliable than a dirty flag every staging site has to remember to set |
| `plan_sent(turn)` | the server took it exactly as it stands |
| `plan_consumed(turn)` | the turn it was for resolved, so throw it away: re-sending would aim last turn's move at this turn's map, at a fleet that may not exist |

`orders_turn` is what tells a live plan from a stale one, and the HUD adopts the
coming turn on the frame anything is first staged — every frame, so there is no
window in which a staged order has no turn against it.

**The bar lists the plan, and grows upward to hold it.** A count on the button is
not something a player can act on: since the batch replaces what the server
holds, the thing that has to be right is the *list*, and the only way to check a
list is to read it. The control row stays anchored the same distance above the
bottom whatever the card does, so SEND never moves out from under a thumb — the
list grows into the new space above it. Past `MANIFEST_LINES` the rest collapse
into a count, because the bar still has to leave a map behind it. The lines are
rebuilt only when a signature-and-state key changes; without that gate this
formatted three strings and walked the fleet list every frame, and nothing else
in this project does per-frame CPU work.

SEND has **four states, and only one of them is interactive** — because "I tapped
it and nothing happened" was the actual complaint, and a disabled button that
still animates a press is indistinguishable from a broken one:

| | button | line above it |
|---|---|---|
| nothing staged | `NO ORDERS`, disabled | what to tap to begin |
| unsent changes | `SEND n`, accent | the plan, amber, "not sent yet" |
| in flight | `SENDING`, disabled | "Sending..." |
| accepted | `SENT`, green, then `ORDERS IN` | the plan, green, "in for turn n" |

`set_enabled` picks a style of its own, so the exact one has to be applied
*after* it.

### Showing a route, without a second pathfinder

**The map draws the path a force will take, and the server computes it.** A
committed route is already in the wire (`view.fleets[].route`, expanded by the
resolver). A *staged* order is not: the client only picks a destination, and the
resolver expands it lane by lane when the turn runs.

The obvious shortcut is to run `path.find` client-side for the preview - the
generator is right there and the map is public. Don't. It is a second
implementation of an authoritative decision, running against a fogged view, and
the day the two disagree the player is looking at a line that lies. `game.route`
asks the server instead, and it calls `resolve.expand_route` - the *same*
function the turn will use.

Two things fell out of that which are worth keeping:

- **An unroutable order is refused when it is issued**, not hours later. The
  route request is what discovers that a destination is beyond
  `max_route_hops`; before it, such an order sat in the bar looking fine and was
  rejected at resolution.
- The preview fields (`path`, `path_from`) are stripped from the batch before it
  is sent. They exist to draw a line; the server expands the waypoints itself,
  against the map as it will be then.

Route segments are pooled GUI nodes, like the fleet markers and the labels, for
the same reasons: constant thickness at every zoom, and no vertex buffer to
rebuild when a plan changes.

### The commander strip

A row of faces under the overview bar, one per force in the field, each showing
its strength. Tapping one selects that commander **and glides the camera to
them** - to where they actually are, part way along a lane if they are under
way, so the view lands on the marker rather than behind it.

It is the roster and the way around the map at once. With a cap of four there
are never enough commanders to need a list, and a player thinks in terms of
"where is Kess", not "which system was that".

The camera **eases** rather than cuts (`focus` in `main/camera.script`): the map
is the one thing the player holds a mental picture of, and a cut leaves them
re-reading the screen to work out what moved. Any touch on the map cancels the
glide - it is theirs again the moment they reach for it.

The strip is rebuilt only when the roster changes, keyed on who is in the field,
where, how strong and which is selected. It has its own Druid instance, because
it is a region that gets rebuilt.

### What moves, and what must not

Two things on the map animate, and the line between them is deliberate.

- **A force under way pulses**; a parked one is still. Position only changes when
  a turn resolves, so without this a fleet crossing a lane looks exactly like one
  sitting on a world.
- **A committed route flows** - the nodes slide along their legs toward the
  destination, which is pinned and larger. A staged route does not: it is a plan
  in the bar, not a force in motion.

**Animating the actual position would be a lie.** A fleet's progress advances one
turn's worth at a time, and where it can be intercepted is decided at the turn
boundary. A marker gliding smoothly between two turns would be showing the player
somewhere the simulation says it never was.

### Keeping up with the turn

**The map polls every ten seconds** (`POLL_SECONDS` in `main/galaxy.script`)
while a game is open. Turns resolve on a schedule measured in hours, so this only
has to be brisk enough that a player watching the screen sees the turn land — and
the request is also what drives the server's lazy resolution, so a polling client
is what makes a game advance at all.

**How far the digest has been read is persisted per game** (`main/seen.lua`).
The client always told the server the last turn it saw - `game.state` takes a
`since_turn` - but `store.seen_turn` was a plain module value, so every launch
asked from turn 0 and got back the whole window the server is willing to send
(`MAX_DIGEST_TURNS`, forty turns). Opening a game you had been reading five
minutes earlier replayed a fortnight. It is saved per game, because a player
with three on the go has read each to a different point.

**The lobby is what that read state is for.** Each of your games shows the turns
that have resolved since this device last read its digest, so "which one has
moved" is answerable without opening all three. It needs nothing from the
server - the row already carries the turn and `seen.lua` already has the rest -
and it is capped at the forty turns `MAX_DIGEST_TURNS` will actually send,
because a game left for a month sits on turn 166 and offering "166 new turns"
promises a read the player cannot have.

### Getting at the one-shot screens

Two screens are one-shot **by design**, which is right for playing and wrong for
looking at them: a turn digest marks itself read the moment it is opened, and a
battle screen needs a battle — which needs an army, a target and several turns of
economy first.

`main/dev.lua` is the back door, gated on `sys.get_engine_info().is_debug` — the
same gate the automation bridge uses, so none of it reaches a release build. The
lobby grows two buttons:

- **REPLAY DIGESTS** clears every read marker (`seen.forget`), so every game
  replays its whole window again.
- **SAMPLE BATTLE** opens the battle screen on a hand-written fight. Its numbers
  are self-consistent — what went in equals what was lost plus what came out — so
  `playback.battle` unwinds it exactly the way it unwinds a real one, and the
  screen exercises its own arithmetic rather than being handed a picture.

It paid for itself on the first tap: the multi-exchange view had never been
reachable without playing a war first, and opening it surfaced both scrub tracks
being dead.

### One battle, exchange by exchange

`main/screens/battle.gui_script` is the receipt for a fight, opened from the
digest's battle rows or from the playback's SEE THE FIGHT. Only *your* battles:
somebody else's is a line in a list, because you were not there to count their
exchanges.

**It is not a reveal.** The sheet's two comparisons said the fight was winnable
before the order was given, and a captain that cannot beat both halves does not
attack - so the screen answers "what did it cost", which in an asynchronous game
is the part that decides the next turn.

**It does not draw ships manoeuvring.** The mock-up it was built from has a
tactical map; there is no spatial simulation inside a battle - exchanges are a
trade of damage, not positions - so formations moving would be the first thing in
this project that shows a player something the game does not know. Two facing
columns that *thin out* instead: your hold unit by unit, because it is yours and
you know it in detail, and theirs as a wall and a name, because that is all a
rival ever shows you.

**It plays.** The exchange list *is* the timeline - each row is a target, the
current one is lit, and a play button walks them at `EXCHANGE_SECONDS` apiece so
the hold thins out in front of you. The first pass had a progress bar anchored to
the bottom of the *screen* with several hundred units of nothing between a
three-exchange battle and its own controls, and no indication anything could be
stepped through at all; content with no card around it reads as a layout that has
come apart. The card is sized to what it holds and the transport sits directly
under the list.

`playback.battle` winds the exchanges backwards from the hold the fight ended
with, which is exact for the same reason the digest rewind is: the log records
what was lost, so it is reversible. `tools/test_playback.lua` checks the rewind
lands on the recorded hold, that a hold only ever thins, and that what went in
equals what was lost plus what came out.

**The `hold` on a `battle` event is a snapshot, taken at the moment.** It was
`captain.units` - the live table - so a captain that marched on and loaded at a
colony before the turn was serialised left the event reporting the hold it ended
the *turn* with, and the screen unwound its exchanges from the wrong end.

### Watching the turn, not reading it

**The digest plays back on the map.** A list of forty turns is a changelog; what
a player wants after two days away is *where the war moved*, and that is a shape
on a map. Opening a digest replays it: markers walk the lanes they walked,
territory recolours as it changed hands, and a transport bar sits where the
order bar does — play, speed, a scrub track with a tick on every turn that had a
fight, and LOG to read it as a list instead.

**The past is rebuilt, not stored.** The client has never been told who held
what forty turns ago and the server does not keep it — state is one current
record, deliberately. It does not have to: **the event log is reversible.**
`claimed` says a system was unowned before it and `battle` names who it was
taken from, so winding today's ownership backwards through the digest gives the
ownership at any earlier turn *exactly*. `main/playback.lua` does that and
nothing else; `tools/test_playback.lua` plays a real game, snapshots who owned
what at the start of every turn, and checks the reconstruction against those
snapshots system by system.

Three things this needed from elsewhere, and would silently be wrong without:

- **`captain_moved` carries the path actually walked.** A captain crossing its
  own territory changed nothing and so emitted nothing at all, which meant the
  one thing worth watching was the one thing the log did not contain.
- **`contact_moved` is what a rival's march looked like from here** — only the
  part inside your detection range, so a fleet crosses your border, is watched
  for a lane or two, and is lost again in the dark.
- **`knowledge()` in `main/galaxy.script` is the single place ownership colour
  is decided**, so overriding it with `store.playback_owners` moves the wash,
  the borders and the star tints together. Only those two layers are rebuilt per
  step (`repaint`); the nebula, dust, lanes and glow do not depend on ownership,
  and rebuilding six layers to change two would make the transport a slideshow.

**Fog is not rewound with it.** What a player could see forty turns ago is not
in the digest, and dimming half the map to guess at it would hide the very
movement the playback exists to show.

**A replay is the one place a marker may animate between systems.** The live map
must not: a fleet gliding along a lane would be claiming a position the
simulation says it never had, and where it can be intercepted is decided at the
turn boundary. In a replay the turn is over, the captain really did cross those
lanes in that order, and the only thing invented is how the seconds were spread
across them.

**It frames what it is showing.** The map opens at the fit zoom where a marker is
four pixels wide, so a playback zooms to `PLAYBACK_ZOOM` and eases the camera to
the average of everywhere something happened that turn — then returns to the
whole map when it ends, because leaving the player zoomed into the last turn's
corner ends every digest somewhere they did not choose to be.

**A digest with nothing in it goes back to being a list.** Forty turns of
"nothing moved" is the changelog this replaced, only slower.

**The transport owns its own Druid region**, so a relayout — a window change, or
the safe-area insets arriving a couple of hundred milliseconds in — does not
rebuild it and it would otherwise stay positioned against the old insets.
`build_chrome` clears `pb_layout` for that reason. Its control row also leaves
the same clearance below it that the order bar's does; six units against the
bar's sixteen reads as the replay being jammed against the bottom of the screen
while nothing else is.

**A turn that lands while you are watching plays out on the spot.** It used to
be parked behind the turn card — accent, "new, tap to read" — which is an odd
thing to offer somebody looking straight at the map it happened on. It plays
immediately instead, with no title card, because they were not away. The HUD
declines mid-aim or under a popup — interrupting somebody part-way through an
action is worse than being a moment late — and declining costs nothing:
**`seen_turn` advances only when a playback actually starts**, so the next poll
offers the same digest again. Advancing it on the background poll was exactly
how digests used to be lost — the next request asks for events *since* that
turn, so the server would never send them again. Watching is what marks it
read, and a *live* turn is marked read even when there is nothing to animate:
your own purchases, a build, a bot marching in the dark. Lighting the card over
a turn where visibly nothing happened is the badge earning distrust. Only an
*arrival* digest with nothing to animate stays parked in `store.pending_report`
for the card to offer in the player's own time — nothing is lost if they never
tap. And afterwards a live playback restores the camera the player had rather
than the whole-map fit: they had chosen a view, which is why they saw it
happen. An arrival or card-opened digest still ends on the fit, because there
was no chosen view to give back.

Two traps live turns exposed, both fixed where the class lives rather than the
symptom:

- **Leaving mid-replay left `playback_active` set**, and the map's poll is
  gated on it - so the next game opened never polled and silently stopped
  advancing. The leave-time store clear resets it (and `playback_owners`,
  which would have painted the next game's map with this one's past). Before
  live turns a replay only ran because the player had just chosen to open one;
  now leaving during one is an ordinary exit.
- **Tapping DONE also pressed END TURN underneath.** The HUD feeds every Druid
  instance every action and the chrome is not rebuilt for a playback, so the
  order bar's button was still registered under the transport - and a single
  tap fired both, silently sending an empty batch that both ends the turn and
  *replaces* any orders already in. This predates live turns (every DONE tap
  ever did it) but they made it constant. While a replay is up, a touch inside
  `pb_zone` now goes to the transport's instance alone - ownership by
  geometry, the same rule as the map boundary.

**Arriving is a title card, then a replay - never a list.** Coming back to a game
used to open the digest as a screen of rows, which is a changelog in front of a
map the player has not seen yet; what they actually want to know is where the
war moved, and that is a shape. `title_card` in `main/hud.gui_script` holds
"SINCE YOU WERE AWAY" and the turn range over the map for a second and a half,
then `playback_start` runs. Three details it needs:

- **A scrim.** Region names are set large and pale and land exactly where a
  centred caption does; without something to sit on the two read as one
  sentence. Each node fades from the alpha it was given, or the scrim brightens
  to full on its way out.
- **A relayout must not swallow the replay.** The safe-area insets arrive a
  couple of hundred milliseconds in - which is exactly when the card is up - so
  the layout branch fires the pending callback rather than dropping it.
- **A digest with nothing to animate is left pending**, not listed. The turn
  card still offers it, in the player's own time.

**The chrome gets out of the way of the thing it describes.** Three rules, each
of which was learned by watching the interface fail at them:

- **A selected system must not sit under its own card.** The sheet covers the
  bottom half, so `focus_pending` in the HUD lifts the star into the visible
  band after the sheet is built - deferred, because how much map is left depends
  on how tall the sheet turned out. It intervenes *only* when the star would
  otherwise be hidden; moving the map on every selection is its own kind of
  clunky.
- **Aiming hands the screen to the map.** `build_sheet` returns nothing while
  `store.aiming` is set, and the order bar carries the origin and the count
  instead. The sheet used to ask the player to "tap where to send" while
  covering half the destinations.
- **The camera clamps against the visible band, not the window.**
  `store.hud_band` is what the map can actually be seen through. Without it the
  galaxy fits the *window* at fit zoom, the camera is pinned by
  `clamp_position`, and a system under the sheet can never be lifted out.

**The system sheet is read top to bottom, in the order a player thinks.** It was
rebuilt from a playtest whose verdict was "way too incomprehensible", and every
rule below came out of one specific thing on it that could not be read:

| in order | and why |
|---|---|
| a colour dot, the name, and CAPITAL | whose it is, and whether it decides the game |
| the region | the only fact on the card the map does not draw |
| **the captain standing here** | everything under it reads differently with one |
| what it takes to capture | see below |
| SHIPYARD | what can be bought, and with what |
| UPGRADES | two slots, and what is in them |

- **Whose it is, before what it is.** The dot is the same mark the map draws
  round the system, so the two are read the same way and the common case needs
  no sentence at all; only a rival's name is worth spelling out, and it goes on
  the region line in `BAD`. "Colony   Antares   Anomaly" went with the rest: the
  kind is already told by what the sheet offers below - a shipyard is a colony -
  and the feature is flavour.
- **"CAPITAL", not "Your capital".** Whose it is, the dot has already said.

- **A number needs a sentence, not a label.** "DEFENDS AT / Fortification 9" was
  a heading and a number with no verb between them. Your own world now says
  "Takes 21 to capture" - the same number, as the thing an enemy has to beat.
  Somebody else's keeps the two comparisons, because those *are* combat, and
  spells them out: "to take it, you need 16 against its defences - you bring
  only 6".
- **The two halves of a fight get an icon each, everywhere.** "1 vs walls 1 vs
  ships" is a sentence a player parses three times over on one card and cannot
  scan at all. `draw_halves` in `main/hud.gui_script` draws a shield and a hull
  instead, and the unit rows, the captain, the rival contact and the target are
  all measured in the same two marks.
- **Buying is a stepper, not a row you tap.** Tapping a row added one and there
  was no way to take one back short of dropping the whole order. `−  n  +` says
  both what it does and that there is a number here to change - and it is 60
  design units, because the 44 it started at is 25 dp, which is a target you
  have to aim at.
- **Both controls grey out for their own reason.** `+` when the purse, the
  berths or the hold cannot take another; `−` at zero. A disabled control that
  still animates a press is indistinguishable from a broken one, which is what
  `ui.icon_button`'s `set_enabled` exists for.
- **The unit names say what the unit is for.** They were Line, Lance and Siege,
  which mean something only to somebody who already knows the rule. Escort,
  Interceptor and Bombard say which one to buy for what. A hold in storage is
  keyed by id, so `units.normalise` carries the old keys across - without that
  every captain in flight comes back empty, and nobody notices until their army
  has quietly evaporated.
- **`SHEET_MAX` is a real ceiling, not a guess.** The sheet has no scroll, so
  content past it is drawn over the order bar. Two slot boxes took the card back
  from ~930 units to ~700, but the cap is 960 and adding a row means checking
  that sum.

**The shipyard says what *this world* makes.** Only the types it has a dwelling
for - the mapping is on the wire, since every building declares what it makes -
so a colony with one dwelling is one row, and a Foundry with nothing out of it
yet still says "0 ready" rather than vanishing until something appears. Each row
carries three numbers that mean different things: what it costs, what is ready
to buy, and what is already standing here.

Buying fills the garrison, so the steppers need no captain present and spend no
order — the bar reads "0 of 3 orders used" while a purchase is staged, which is
the whole point of it being free.

**MOVE UNITS opens the transfer popup**, and only when there is something to
trade: a control that opens two empty columns is a control that has taught the
player it does nothing.

**`main/screens/transfer.gui_script` is where the whole combat design is visible
at once.** Every fight is two comparisons a player does in their head before
committing, and this is the one screen where both move as they decide — the
captain's two halves and the world's two halves, live, as the split changes.
Push with these, or hold with them.

Steppers rather than sliders, and it was close. A slider can *show* the shared
capacity as a dead zone on the track, which beats three `+` buttons greying for
a reason that is off-screen. Against it: the ranges are tiny (a captain carries
six, a veteran nine), the three rows share one budget, and a step would be about
35 dp — under a fingertip, on the one screen where an off-by-one is a wrong
army. The deciding argument was vocabulary: buying and transferring are the same
act, deciding a composition against a budget, and one control for both is worth
more than a gesture. TAKE ALL is what the slider was actually for — the tap
count.

The popup rebuilds itself whole on every change rather than patching, because
the row set changes as a type empties on one side and every number on the card
depends on the split. Gated on an actual change, so it is not per-frame work.

**Upgrades are two boxes, and each one opens a popup.** They were four rows with
a name, a line of what they do and a price - a catalogue on the bottom of the
longest card in the game, which never said the one fact that matters: a colony
gets *two* of these, ever. Two boxes say that without a sentence, and "1 of 2
slots used" went with the sentence.

| box | says | opens |
|---|---|---|
| empty | `+` | pick something to build |
| staged | the name, "staged" | nothing - it is in the order bar, where it can be taken back |
| built | the name, "built" | what it does |
| built, with a verb | the name, "tap to use" | that verb - so far only the Admiralty's |

`main/screens/slot.gui_script` is the popup, and it **answers through the store**
rather than acting: staging spends the turn's allowance and only the HUD knows
what is left of it, and a popup cannot act after Monarch has begun tearing it
down. `store.slot_popup` is the request to open one and `store.slot_request` is
what it decided, both consumed in the HUD's `update`.

**A slot that promises a verb has to have one.** Yards, Works and a Bastion work
by standing there, so their boxes say "built" and their popup says so; only the
Admiralty says "tap to use". Labelling all four the same and then opening a card
that says there is nothing to do is how an interface loses the word.

**Ordering a captain starts in one place: the round face in the strip.** Tapping
it aims, tapping the same face again cancels - aiming takes the whole map, and a
mode you can only leave by finishing it or by hunting for CANCEL is a mode that
catches people. The sheet's captain row is a statement, not a second way in;
when it was one, tapping a colony had to hand the map over instead of opening
its card, which is why **tapping a system now always opens the sheet unless a
move is being aimed**.

**The map has three interactive layers.** The *system sheet* is rebuilt whenever
the selection changes, because its content varies enormously — a waypoint you
have never visited is three lines, a developed colony is garrison, population,
defence, three installations and a list of fleets. *Fleet markers* are GUI nodes
rather than world geometry: a marker wants to stay a constant size at every zoom
and carry a crisp glyph, which is exactly what the labels already do, and it
avoids rebuilding a vertex buffer whenever a fleet moves. `store.aiming` is the
one piece of interaction state — set by SEND or by tapping a fleet, consumed by
the next tap on a system.

**A name is not scenery.** The map is deliberately two hundred stars most of
which a player never touches, and naming them all turned it into a wall of words
with the lane graph buried underneath. Labels are chosen by **relevance to the
player**, rebuilt whenever what makes a system relevant changes - the selection,
the turn, the captains - and never per frame, because it walks every star and
sorts them.

| tier | what |
|---|---|
| selected | what the sheet is describing |
| capital | anyone's |
| captain | where one stands, and everywhere its route goes |
| held | somewhere someone holds, including you |
| frontier | unclaimed, but adjacent to something of yours - where a captain can be sent next |

Everything else is never named. Zoom decides which tiers are admitted, pulled
back rather than pushed out: at a distance you want to know whose space you are
looking at, not what every rock is called.

The ranking this replaced was static - colony beats outpost beats waypoint, then
by how brightly the star was drawn, computed once per galaxy. It had no idea
which systems were yours or where your captain stood, so it faithfully named the
prettiest forty stars and none of the six that mattered. **Colour carries
ownership** now, so whose space it is reads without being read, and the label
budget is a filter (22 at most) rather than the truncation of a much larger set.

**Glyph size still ranks what a system is for, but the emoji itself is the
cue now.** `star_half` in `main/galaxy.script` scales a colony at 1.45, an
outpost at 1.15, a waypoint at 0.70 and a capital at 1.9, with star-class
variance deliberately damped (`0.85 + 0.3r`) — a glyph squeezed small stops
being readable long before a disc does. Note the sizing helpers have to be
declared *above* the mesh builders — a Lua local is not visible to a function
defined before it, and putting one lower silently breaks every build with
`attempt to call global ...`.

**`druid.no_auto_input = 1` is set in game.project, and the project would be
unusable without it.** Druid manages input focus for you: an instance posts
`acquire_input_focus` when it gains an input component and, in
`druid_instance:final()`, posts **`release_input_focus`** — and that message goes
to `.`, the whole script, not to that instance. This project runs *several*
Druid instances in one gui script (see the region rule below), so finaling any
one of them made the entire scene deaf, and the surviving instance never
recovered: its own `input_inited` flag was still true, so it never re-posted
`acquire_input_focus`.

The symptom is savage to read, because nothing errors and the *first* few
interactions work. Staging an order rebuilt the system sheet, which finaled the
sheet's instance — and from that moment SEND, EMPIRE and the turn card were all
dead, on device and desktop alike, while the map still panned. Every gui script
here already acquires its own focus in `init`, so Druid's automation was pure
liability. Turning it off is the supported switch, not a workaround.

**Druid needs three further adaptations here, all in `main/ui.lua`:**

- `ui.gui_action(action)` — Defold reports input in the configured display size
  while this project lays GUI out in the aspect-derived view space. Druid
  hit-tests with whatever action it is given, so it must be converted. It
  returns a *copy*, because the same action goes to other listeners.
- `ui.install_druid_picking()` — replaces `druid.helper.pick_node`. Druid asks
  `gui.pick_node`, which resolves against the configured 720x1280 display no
  matter what projection the render script used, so **any node laid out above
  y=1280 is unpickable**. Buttons near the bottom of the screen worked and
  buttons near the top silently did nothing, in every coordinate space. Since
  every node here is created in code with a known position, size and pivot, an
  axis-aligned test against those is exact. Call it before `druid.new`.
- **A region that gets rebuilt needs its own Druid instance**, not per-component
  bookkeeping. Helpers register components the caller never sees — `ui.tabs`
  makes one button per tab, `ui.scroll` makes a scroll — so a screen that
  carefully removed *its* buttons still left those behind, pointing at nodes it
  had just deleted, and the next touch anywhere on screen threw
  `druid/base/hover.lua: Deleted node`. `ui.region(instance, nodes)` finals the
  instance and *then* deletes the nodes, in that order.

  **`late_init` is not run from `update` — it is scheduled on a
  `timer.delay(0)` when any component is created, and *nothing* cancels it.**
  Not `final()`, not `remove()`. So it fires on the next frame whether the
  instance still exists or not, pops a component whose node has since been
  deleted, and `on_late_init` walks the dead node looking for a stencil:

      druid/helper.lua:338: Deleted node
        get_parent → get_closest_stencil_node → button.on_late_init → late_init

  That makes it a **race**, not a mistake in the teardown order — it only throws
  when a region is rebuilt within a frame of a button being made in it: a fast
  second tap, a relayout landing on the frame a card was built, a playback
  stepping at 4x. Which is why it was intermittent, and why it appeared to come
  from screens with no connection to whatever had just been touched.
  `ui.region` cancels the pending timer before finaling, which closes the class
  wherever it happens. Draining the queue instead would be worse: `final` leaves
  the interest lists populated, so `late_init` would re-acquire input focus for
  an instance being thrown away.

  **`druid:remove()` is not an alternative either, because it is usually
  deferred.**
  `DruidInstance:update` and `:on_input` both set `_is_late_remove_enabled`, and
  while it is set `remove()` queues the component and returns `false` without
  touching it. Anything rebuilt from an update, an input callback or an async
  response — which is all of them — therefore deletes its nodes and leaves the
  components registered until the *end* of that call. `late_init()` runs before
  that, pops the still-registered component, and `on_late_init` walks the node's
  parents looking for a stencil:

      druid/helper.lua:338: Deleted node
        get_parent → get_closest_stencil_node → button.on_late_init → late_init

  The lobby's game list did exactly this, and the race window is the gap between
  a row button being created and Druid's first update over it — which an async
  `game.list` response lands in whenever two arrive close together. The empire screen's tab body and
  the HUD's system sheet each own one.
- **A Druid click callback carries no touch position.** It is
  `on_click:trigger(context, params, button)` — the third argument is the button
  component, so reading `event.x` off it gets nil and the handler quietly does
  nothing. Anything that needs to know *where* a control was touched, like a
  scrub track, must have the position kept for it by `on_input`. Both scrubbers
  in this project were written the wrong way and did nothing at all, silently,
  from the day they were added.
- **Never return `druid:on_input`'s verdict verbatim from a scene that shares
  input with the world.** Druid reports a touch as handled whenever one of its
  hover components tracked it, which is *every* touch anywhere on screen. The
  HUD instead claims a touch only when it also lands inside one of the
  rectangles it published (see below); returning Druid's answer as-is would
  swallow the map's pans.

### The interface kit (`main/ui.lua`)

One module owns the look, and every screen composes from it, so a change to the
corner radius or the type scale happens once rather than in four scripts.

- **Tokens, not literals.** A near-black ground (`BG`) with cards a few percent
  lighter (`CARD`, `CARD_ALT`, `CARD_HI`) is what makes a dark interface read as
  layered instead of as one flat sheet. Text has exactly three weights of
  emphasis (`TEXT`, `DIM`, `FAINT`); a fourth is how dark UIs turn to mud. One
  interactive colour (`ACCENT`), and one colour per resource so the mapping is
  learned once.
- **Panels are 9-slices of two generated shapes** — a rounded rectangle and a
  capsule — tinted by the node colour. So `panel`, `pill`, `card`, `divider`,
  `progress` and every badge come from the same two PNGs.
- **9-slice margins are clamped to the node** (`ui.set_slice`). A margin wider
  than half the node leaves no middle to stretch and Defold draws the corners
  over each other: a 10x10 dot with a 31px margin rendered as a filled square.
- **The capsule is sliced horizontally only.** Its texture is a circle, so every
  pixel outside the caps is transparent; slicing it vertically as well stretched
  those transparent corners across the middle and the node came out as a cross.
  Anything as tall as it is wide is a dot (`ui.dot`) and a plain scale is already
  right.
- **Neither slice survives a node much thinner than its own texture, so a thin
  bar is composed instead** (`ui.bar`). `panel`'s margins clamp to half the node
  and the clamped corner lands partway up the rounded curve, so the body draws
  shorter than the node and tapers away; `pill`'s caps are drawn at their own
  31px width whatever the node's height, so a twelve-unit track tapers over
  thirty-one units at each end. Both produce a **lens** — pointed at both ends,
  fattest in the middle — which is what the playback's progress bar was until it
  was drawn as two `ui.dot` caps with a `solid` rectangle between them.
- **Type sizes are design pixels.** Both faces are distance fields baked at one
  size, so a size is just a scale factor and any size stays crisp.

**Sizes are in design units, and a design unit is much smaller than it looks.**
The design space is 720 units wide; a typical phone is 411 dp wide, so one unit
is about **0.57 dp** and every number in the kit has to be roughly 1.75x what it
would be in dp. The first pass used dp-sized numbers and shipped an interface
whose body text was 10 dp and whose buttons were 32 dp — legible in a screenshot,
unusable with a thumb. The floors now held: body text 15 dp (26 units), tap
targets 48 dp (88 units).

Fonts are **Space Grotesk** (SIL Open Font License 1.1,
`main/fonts/SpaceGrotesk-LICENSE.txt`). `ui.font` / `ui_bold.font` have no
outline; `map.font` keeps one, because star names sit over a nebula and need it.
The engine ships only a monospace face, so this is vendored.

google/fonts carries Space Grotesk **only as a variable font**, and Defold's font
compiler bakes a variable font at its default instance — which would give one
weight, not two. The two static files were instanced with fontTools:

```bash
python3 - <<'EOF'
from fontTools import ttLib
from fontTools.varLib.instancer import instantiateVariableFont
for wght, out in [(400, "SpaceGrotesk-Regular.ttf"), (600, "SpaceGrotesk-SemiBold.ttf")]:
    f = ttLib.TTFont("SpaceGrotesk[wght].ttf")
    instantiateVariableFont(f, {"wght": wght}, inplace=True)
    f.save("main/fonts/" + out)
EOF
```

`updateFontNames` has to stay off: the STAT table has no named entry at 600 and
fontTools refuses rather than inventing one.

**Two traps in the kit worth knowing:**

- **A wrapped text node is centred on its whole block**, so adding a second line
  pushes the first one *upward*. Anywhere text sits beneath something else, pass
  `anchor_top` — without it a two-line effect sentence climbed into the heading
  above it on every research card.
- **A screen that rebuilds itself must delete what it made.** `ui.collect(list)`
  records every node the kit creates; the HUD relayouts on a window change and
  on the safe-area insets arriving, and without this each rebuild leaked a whole
  layout until the scene ran out of nodes.

### Commander portraits

Seventy-two faces in `main/assets/portraits/`, their own atlas
(`main/portraits.atlas`), drawn by `ui.portrait`. **Third-party art, not a build
artifact** - unlike everything in `main/assets/ui/`, these are not regenerable
from a script, and `main/assets/portraits/CREDITS.txt` records the artist and
that the licence has not been established.

**They are grouped by race, twelve each.** The source set of five hundred is not
labelled, but it is drawn in species, and every race already declares a colour
that lands on one of those groups almost exactly - so the grouping is *measured*
from each image's dominant hue rather than classified by hand:

| race | hue | what it looks like |
|---|---|---|
| terran | blue | uniformed, armoured humanoids - a navy |
| vorn | red | devils and revenants |
| ashai | green | orc and plant folk |
| kepler | violet | tentacled, scholarly, strange |
| cartel | gold | ornate and flashy |
| silicate | cyan | ice and glass |

Two things are traded off inside a band and both matter: **fit**, how much of the
subject is actually that hue, so a race reads as one species rather than a
colour-wash; and **variety**, because the source is ordered by character with
several variants of each in a row, so the best-fitting dozen are otherwise one
person twelve times. Picks are kept a minimum apart in the source order for that
reason.

Twelve per race rather than one per surname, because six races would be 240
images and a player currently raises exactly one officer. Past twelve the index
wraps.

Portraits are masked to a disc at import and drawn with a ring
(`ui.portrait`, `ui.ring`), so the ring covers the mask's soft edge instead of
leaving a pale halo behind it.

`tools/import_portraits.py` records the provenance. **The order is
load-bearing.** A portrait is chosen by the player's race plus the same index as
the surname (`commanders.portrait`), so the nth officer a player of a given race
raises always has both the same name and the same face; changing the bands, the
count or the tie-breaks silently reassigns every existing commander's portrait.
The bands are a *method*, not a record - `MANIFEST.json` alongside the images is
what says which five hundred became which seventy-two, and is the only way to
see that a threshold tweak moved everyone's face. There is a fallback from
surname to index for records raised before officers carried a number, without
which every one of them shared a single face.

`tools/test_wire.lua` checks that every id the sim can name resolves in the
atlas. Nothing connects the two but a string, and `ui.portrait` swallows a
missing one on purpose - so a mismatch would quietly put the whole roster in the
fallback face rather than erroring.

The importer also makes the baked-in black background transparent, by flooding
inward from the border. Keying out *every* black pixel is not an option - this
is pixel art and its outlines are black, so that punches holes through the
character.

### Safe area

The device's notch, punch-hole and gesture strip are respected by
[extension-safearea](https://defold.com/extension-safearea/), in **custom mode**
(`safearea.resize_game_view = 0`). That matters: the default "easy mode" shrinks
the game view and fills the remainder with a solid colour, which is exactly the
letterbox bars this project does not want. In custom mode the world, the nebula
and the starfield still draw edge to edge *under* the cutout, and only the chrome
is held clear of it.

`main/safearea.lua` does the two things a bare `get_insets()` call does not:

- converts the values, which arrive in **framebuffer pixels**, into the view
  units every layout number here uses — and the horizontal and vertical ratios
  differ, because the view is the design width by an aspect-derived height;
- **polls until they settle.** `get_insets` reports `STATUS_NOT_READY_YET` for up
  to a couple of hundred milliseconds. A layout built from the zeroes returned in
  the meantime sits under the notch for the rest of the session, so it publishes
  `store.safe` plus a `safe_revision` that screens watch: the HUD rebuilds on a
  change, and the lobby defers its first build until the values are known (or a
  0.4 s grace period expires, for platforms that will never answer).

`ui.inset()` is the one place that adds the design gap to the device insets;
every screen takes its outer margins from it. On the test device the reported
inset is `top 66` view units and zero elsewhere — the punch-hole camera, with no
bottom inset because `android.immersive_mode` hides the navigation bar.

Map labels are held inside the horizontal insets too, and any name that will not
fit on either side of its star is simply not drawn: a name sliced by the screen
edge is worse than no name.

### Input and gestures

`main/gestures.lua` is a pure state machine turning a list of active touch
points into pan / zoom / tap. It is deliberately engine-free because multi-touch
cannot be injected into an Android device from a workstation, so a test harness
is the only way to verify pinch at all.

`main/camera.script` feeds it from two sources and applies whatever it reports:

- **Device**: the `TOUCH_MULTI` binding delivers `action.touch`. Defold *also*
  synthesises a `MOUSE_BUTTON_1` "touch" action for the primary finger, so the
  first frame carrying a touch table latches `touch_driven` and the mouse path
  stops running — otherwise every pan is applied twice.
- **Desktop**: mouse press and release carry the bound action id, but mouse
  **movement arrives with `action_id == nil`**. A handler keyed only on the
  bound id sees clicks but never drags, and panning silently does nothing.

**Input ownership is decided by geometry, not by focus order.** The HUD
publishes the rectangles it occupies into `store.hud_zones` — the overview bar,
the order controls, and the selected-system card while it is up — and:

- the recogniser ignores any gesture that *starts* inside one, and reports
  `blocked` so the camera can decline the input as well rather than consuming a
  touch it did not act on;
- the HUD claims a touch only when Druid handled it *and* it landed inside one
  of those rectangles.

Either side can therefore acquire input focus first and the result is the same,
which matters because acquisition order between a GUI scene and a script is not
guaranteed. It is where a drag *begins* that decides, so a pan that wanders
under the controls keeps working.

**The multi-touch action must be named `touch_multi`.** Druid's drag component
does this, in `druid/base/drag.lua`:

```lua
local act = helper.is_mobile() and const.ACTION_MULTITOUCH or const.ACTION_TOUCH
if action_id ~= act then return end
```

`ACTION_MULTITOUCH` defaults to `hash("touch_multi")`. This project's binding
called the `TOUCH_MULTI` trigger `"multitouch"`, so on a device Druid received
*no* drag events at all — and the failure was invisible, because buttons take a
different path (`pressed`/`released` on the synthesised `"touch"` action) and
kept working. Every scroll region in the game was inert on hardware until the
binding was renamed. `main/camera.script` is unaffected either way: it keys on
`action.touch` being present rather than on the action id.

**A full-screen popup claims input rather than blocking it.** `ui.modal_input`
runs the popup's Druid instance and then returns `true` unconditionally, so the
map and its camera get nothing while the popup is up. The obvious alternative —
a Druid `blocker` covering the screen — also sits in front of the popup's own
scroll regions and eats their drags.

### One coordinate space

**Everything — the world projection, GUI nodes and input — is in the design
resolution (720×1280), never the framebuffer.** This is deliberate and was the
source of two separate bugs before it was unified:

- Defold reports `action.x/y` in design coordinates, with **y up from the
  bottom**. GUI nodes positioned in framebuffer pixels (what `render.get_window_*`
  returns, which differs whenever the window is resized or `high_dpi` is on) meant
  taps never landed on the button that was drawn.
- The render script therefore builds the world projection itself from
  `store.camera` rather than using a camera component, so the visible world width
  is exactly `design_width / zoom`. That relationship is what lets the HUD place a
  label with `(world_x - cam_x) * zoom + width/2` and have it land on the star.

`main/store.lua` is the shared state between camera, map and HUD — a plain module,
which works because `script.shared_state` is on (see below). The render script
publishes the viewport into it; the camera publishes its position and zoom.

Hit-test HUD widgets against rectangles you positioned yourself, not
`gui.pick_node` — pick_node applies the scene's own screen-to-node conversion,
which is a different space again.

`game.project` has no comment syntax — a `#` line makes bob fail with a bare
"Could not parse" and no line number. Keep explanations in this file instead.

## Non-default `game.project` settings

- **`script.shared_state = 1`** — *all* scripts, gui scripts and render scripts
  share **one Lua state**, so a `require`d module is a single process-wide
  instance. `main/store.lua` depends on this. It also means module-level tables
  are global mutable state and globals leak between scripts.
- **`display.width/height = 720x1280`** — portrait. This is the design
  resolution and, per above, the only coordinate space in the project.
- **`display.high_dpi = 1`** — the backbuffer is larger than the design
  resolution. Never assume window pixels equal design units.
- **`bootstrap.render = /main/render/galaxy.render`** — a custom pipeline; the
  builtin one cannot express the per-layer blend modes this map needs.
- **`android.immersive_mode = 1`** — hides the Android status and navigation
  bars, which otherwise sit on top of the HUD.
- **`android.package = com.dg.galaxy`** — Defold's default is the placeholder
  `com.example.todo`, which collides with every project that never changed it.
- **`safearea.resize_game_view = 0`** — custom mode; see Safe area above. The
  default shrinks the view and letterboxes the remainder.
- **`graphics.max_font_batches = 512`** (default 128) — the interface interleaves
  text and box nodes heavily, and every text node between two boxes is its own
  batch. Past the limit the font renderer silently *stops drawing*: the
  selected-system card came up completely blank with nothing in the log but a
  `Fontrenderer: Render object count reached limit` warning. `max_draw_calls` is
  raised alongside it for the same reason.
- **`druid.no_auto_input = 1`** — stops Druid managing input focus. Its
  `final()` posts `release_input_focus` for the whole script, which deafens a
  scene that runs more than one Druid instance. See Druid above.
- **`native_extension.app_manifest = /galaxy.appmanifest`** — excludes physics
  from the built engine. Nothing has ever used it, and dropping Box2D, Bullet and
  the `[physics]` settings took the stripped release `libgalaxy.so` from 4.1 MB
  to 3.6 MB (APK 6.3 → 5.8 MB). The stub `physics_null` has to be linked in its
  place; removing it too is a link error, not a smaller binary. Excluding
  anything means the engine is relinked, so bundles go through the extension
  build server - already true because of the automation bridge.
- **`automation_bridge.application_api = 1`** — lets the game publish state to
  the bridge. Debug builds only. See "Driving a running build" above.

## Driving a running build

`tools/drive.py` talks to a debug build through
[extension-automation-bridge](https://github.com/defold/extension-automation-bridge),
which serves an HTTP API on Defold's engine service port. **Release builds expose
neither the endpoint nor the `automation_bridge` Lua module**, so none of it
ships - it cost nothing in the 5.8 MB release APK.

```bash
adb forward tcp:8001 tcp:8001          # device; desktop uses the editor's port
python3 tools/drive.py state           # transform, selection, staged orders
python3 tools/drive.py find EMPIRE     # visible text and where it is
python3 tools/drive.py click RESUME    # click by meaning, not by pixel
python3 tools/drive.py star "Rigel VI" # where a star is, in device pixels
python3 tools/drive.py tapstar "Rigel VI"
```

**Select by meaning, never by coordinates.** Hardcoded taps rot: RESUME moved the
moment the lobby held seven games, and a stale constant silently clicks nothing.

**`tap` takes framebuffer pixels, top-down — and the editor's window changes size
between runs.** Half a session's worth of "the button did not respond" was
coordinates computed against a framebuffer that had been 1440×2560 two builds ago
and was 1440×2102 by the time they were used. Re-read the size from a fresh
screenshot every time rather than carrying one forward.

**`main/automation.lua` exists because the bridge's own GUI bounds are the wrong
space here.** It reports node positions against Defold's *configured* display,
and this project renders through a GUI projection the render script builds
itself - the identical reason `ui.install_druid_picking` had to replace
`gui.pick_node`. So the game publishes the transform (view size, framebuffer
size, camera, zoom) as bridge state, and the client converts world to device
exactly as the map does. Star positions are regenerated from the seed under
luajit rather than transmitted, since the galaxy is a pure function of it.

Working this out by hand first is what makes the point: two reference taps gave a
camera of `(-191.75, 243.29)` at zoom `0.37181` against the true
`(-184.38, 256.88)` at `0.37131`, and every star tap missed.

**Known limitation:** the element query returns the star labels and the top bar,
but not the system sheet's own buttons. `state` and `tapstar` are unaffected -
they do not depend on it - and `click` works for anything it can see.

## File formats

Defold source files (`.collection`, `.go`, `.atlas`, `.gui`, `.sprite`, `.input_binding`, …) are **protobuf text format**, not JSON — `.gitattributes` maps them to JSON5 only so GitHub highlights them. They are hand-editable and diff cleanly; match the existing style (unquoted keys, `key: value`, nested `block { … }`, quoted strings). References inside them are absolute project paths and point at *compiled* artifacts — note the trailing `c` in `main_collection = /main/main.collectionc`.

`.internal/` holds editor session state (port, token, downloaded libs, Lua annotation stubs for the LSP). Never edit it or commit it.

## Known gaps

The game is a foundation being built back up, so most of what is missing is
missing on purpose. These are the things that are *not* on that plan, or that
will bite whoever touches them.

- **Only the map wears the atlas theme.** Every GUI screen - lobby, setup,
  sheet, transfer, battle, report - is still the dark chrome, deliberately (the
  mockup kept it dark too), but the interface kit's tokens have never been
  looked at next to the parchment and a re-theme of the chrome is an open
  project of its own.
- **The label zoom tiers are still anchored to the old fit zoom.**
  `STAR_LABEL_MIN_ZOOM` (0.30) and the lowest `LABEL_TIER_ZOOM` entries sit
  below the new zoom floor (~0.7), so they are always-on rather than wrong -
  the visible behaviour was judged fine on screenshots - but the constants no
  longer describe a reachable range.
- **Ownership rings read oversized on waypoint glyphs.** The ring is 1.6x the
  glyph's half-extent everywhere; a sparkle occupies much less of its quad than
  a castle does, so its ring floats. A per-kind ring scale is the obvious fix.
- **The emoji sheet ships uncompressed.** 1024x1024 RGBA plus mips is ~5.3 MB
  of texture memory - fine today, but `galaxy.texture_profiles` is where
  device compression would go if it ever matters.
- **The Android digest constant is unverified since the rename.** Seed 424242's
  `3805718957` is confirmed on macOS and standalone LuaJIT; the arm64 Android
  runtime has not printed it yet (names are pure string work, so agreement is
  expected, not proven).
- **The battle screen's visual treatment is unresolved.** What is there is the
  *derived* reading: pips that thin out, a list of exchanges, nothing drawn that
  the simulation does not know. It is not what the mock-up it came from
  pictures, and the author has said so. The open question is whether the panel
  should become **representational** instead - formations and movement invented
  for the screen, driven by the real per-exchange numbers but not claiming to be
  positions the sim has. That is a legitimate choice and would change the answer
  completely; it wants deciding before anything is redrawn. The data underneath
  is settled either way.
- **The debug strip in the lobby is a back door, not a feature.** `main/dev.lua`
  gates it on `sys.get_engine_info().is_debug`, so it costs a release build
  nothing — but it is the thing most likely to be deleted wholesale one day, and
  it should come out in one piece when it is.
- **Nothing is ever lost at the border.** A captain that cannot beat both halves
  does not attack, so there are no failed assaults - only battles that were not
  started. That keeps the sheet's arithmetic honest but means the map has no
  gambles in it at all, which may eventually be a flatness worth revisiting.
- **The order allowance is fixed at three and nothing raises it.** It is the
  obvious thing for a fifth building to buy, and the obvious thing to scale with
  empire size; neither exists, so a large empire and a small one get the same
  number of decisions.
- **The system sheet has no scroll.** It is capped at `SHEET_MAX` and content
  past that is drawn over the order bar. A colony of yours with an embarkation,
  four buildings, a captain and a rival in sight is close to the cap already.
- **Half of each race is still inert.** `modifiers.of` now folds speed, hops,
  vision, attack and defence, so races differ meaningfully - but growth,
  industry, research, capacity and the cost keys are read by nothing until
  production returns.
- **A boxed-in player still has no way back.** Combat means a border can be
  pushed and a fallen empire's ground falls open again, which is most of the old
  version of this - but nothing rubber-bands and income is linear in territory,
  so falling behind still compounds. The sweep did not touch it; what it changed
  is that money now runs out for *everyone*, so a leader cannot bank an
  insurmountable purse.
- **A battle is one comparison, so there is nothing to play back inside it.**
  The turn digest replays on the map, but a battle resolves instantly and has no
  internal timeline - so a battle-summary screen (fleets closing, reinforcements,
  a retreat, a scrubber) has nothing to animate until armies have a shape.
  `battle` already carries who defended and with what, which is the part that
  would otherwise have to be retrofitted.
- **The playback shows movement but not the fighting.** A battle recolours the
  system it happened at and gets a tick on the scrub track; it does not get a
  moment of its own, which is the turn a player would most want to stop on.
- **Existing games from before the rebuild are dead.** Their stored state has no
  capitals or captains, so `holds_capital` is false for everyone and they end on
  the next resolution. There is no migration and there should not be one.
- **Combat is unverified on a device.** The sim, the server and the full RPC
  round trip are covered, and the desktop client has been driven through a
  battle, but the strength badge, the "N to take" line and the battle rows in
  the digest have only been seen on desktop. The *economy* is device-verified —
  a build → buy → garrison → transfer loop has been driven on hardware through
  the real RPCs — so what is left unseen there is the fighting.
- **`drive.py` cannot see the system sheet's own buttons.** The bridge's element
  query returns star labels and the top bar but not the sheet, so those still
  have to be tapped by position. `state` and `tapstar` are unaffected.
- **A route can only be set one waypoint at a time from the map.** The
  simulation takes a full waypoint list and expands it lane by lane, and the
  order shape and tests cover it, but the only gesture wired up is "tap a
  destination".
- **A real two-finger pinch has still never been performed.** The zoom buttons
  cover the range, so this is no longer load-bearing, but `gestures.lua`'s pinch
  path is verified only by `tools/test_gestures.lua` and has never run against
  real hardware.
- **A fleet marker's name can land on top of a star label.** The label pass
  rejects label-on-label overlaps, but markers are a separate pool and are not
  part of that test, so at close zoom "Kess" prints through "Talitha's Landing".
  Only visible since there was a way to zoom in.
- **A route longer than `ROUTE_POOL` segments draws only its first 64 legs.**
  Pooled nodes cost whether or not they are used, so the pool is sized for a
  busy turn rather than the theoretical maximum.
- The safearea extension logs `ERROR:ENGINE: Could not find '@render' socket`
  once at startup on Android. It is benign - the extension reaches for the
  render system before it exists - but it is noise in every log.
- The turn digest is capped at 40 turns server-side and 140 rows client-side. A
  game left unattended for weeks otherwise produced an event list that exhausted
  the GUI node budget outright.

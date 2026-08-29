# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this project is

`realm` — a portrait-orientation mobile prototype of a 4X-style map. A single
integer seed deterministically generates **one continent on a hex lattice**:
~220 land tiles grown cell by cell out of a sea, carved into named provinces,
drawn as hand-drawn hexagonal terrain art with a Noto emoji on the places worth
holding, on a world much larger than the viewport that the player pans and zooms
around.

A local **Nakama** backend (docker compose) authenticates by device id and is
authoritative for the map: it generates it and ships it to the client. The client
keeps its own copy of the generator purely as an offline fallback.

**The vocabulary is a medieval realm, in the code as well as on screen**:
`realm/` generates it, a place is a `tile`, an officer is a `commander`, a force
is an `army`, a named stretch of country is a `province`, the three kinds of
place are `city` / `holding` / `wilds`, a player's home is their `seat`, and the
currency is `gold`.

Two things deliberately kept the old name. `route` stayed `route` because
`march` is already a place-suffix and `Marches` a province noun, so seeds produce
"Harrowmarch" and "The Inner Marches" and `commander.march` would read as a
place. And the order kind `resupply` stayed, because it means "load the hold" -
it is about units, not money, so following `supply -> gold` there would have been
wrong.

The app's own identity is unchanged: `com.dg.galaxy`, `libgalaxy.so` and the repo
directory still say galaxy. Renaming the Android package orphans every installed
debug build and buys nothing.

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

`bob.jar` is compiled for Java 25; the tile `java` (SDKMAN, Java 21) fails with `UnsupportedClassVersionError`. Use the JDK bundled with the editor:

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

`realm/` is pure Lua with no engine dependency, so the whole generator runs
under standalone `luajit` (installed at `/opt/homebrew/bin/luajit`, the same
LuaJIT 2.1 the engine embeds). This is by far the fastest way to iterate on
generation — no build, no window, ~5 ms per map:

```bash
luajit tools/verify_determinism.lua        # digests for a spread of seeds
luajit tools/preview_map.lua 1337 4 > /tmp/m.json && python3 tools/render_map.py /tmp/m.json /tmp/m.png
```

`tools/render_map.py` is an offline sketch of the renderer (PIL). It is not the
game renderer, but it draws **the same art the engine does, resolved by the same
module**: `tools/preview_map.lua` carries `tiles[].tile` and `tiles[].emoji` out
of `main/theme.lua`, so a look approved in the sketch is a sketch of the same
decisions rather than a parallel guess. It is the right place to try a visual
change first — `... /tmp/m.png detail` renders at 3x and crops the centre,
roughly the game's mid zoom. The second argument to `preview_map.lua` places that
many seats with the real opening-state picker, so 🏰 can be judged with no
game running.

There is no automated check of the interface itself; it is verified by building
to the device and reading screenshots (`adb exec-out screencap -p > shot.png`),
or on desktop through `tools/drive.py`.

`tools/make_ui_textures.py` regenerates the interface atlas in `main/assets/ui/`
**and rewrites `main/ui.atlas`**; every PNG in that directory is a build artifact
of its script, not hand-authored art.

**Two importers, and neither is a regeneration.** Both bring in third-party art
and record provenance beside it - which source became which, at what size, under
what terms:

| | reads | writes |
|---|---|---|
| `tools/import_tiles.py` | `M.TILES` x `M.BIOMES` in `main/theme.lua` | `main/assets/tiles/*.png` + `main/tiles.atlas` |
| `tools/import_emoji.py` | `M.EMOJI` + `M.UNIT_EMOJI` + `M.FACE_EMOJI` in `main/theme.lua` | `main/assets/emoji/ui/*.png` + `main/emoji.atlas` + `main/emoji_ui.lua`, **and** `main/assets/portraits/*.png` + `main/portraits.atlas` |

There used to be a third, `tools/import_portraits.py`, and it is gone: the
officers' faces are Noto emoji now, so they come from the same place and the
same script as every other glyph. See **Commander portraits** below.

`import_tiles.py --src` points at the `foundation_tiles` pack (default
`~/Downloads/foundation_tiles`). It copies the 30 selected ground tiles **byte
for byte at their native 238x207** and never resizes or trims them — that is
exactly the bounding box of a flat-top hexagon of size 119, which is what lets
plain sprite quads tessellate, so `SPRITE_TRIM_MODE_OFF` in the atlas is
load-bearing rather than a default.

**There is one art vocabulary now, not two.** The map used to pack its glyphs
into a sheet sampled by UV rect from a mesh shader, while the interface used
named atlas images, because a GUI node cannot be handed a UV rect. Drawing the
map with *sprites* removed that asymmetry — a sprite cannot take a UV rect
either — so both go through `main/emoji.atlas` and `main/emoji_ui.lua`, and
`sheet.png` and `emoji_sheet.lua` are gone. Changing which emoji anything uses is
still one edit to `main/theme.lua` plus a re-run; `test_wire.lua` fails if the
resolver can name art the atlas lacks.

**Three tables, two sizes.** `M.EMOJI` is the map and exports at `M.GLYPH_PX`
(224), because a map glyph is a sprite scaled to the hex and can fill the screen
at the closest zoom. `M.UNIT_EMOJI` and `M.FACE_EMOJI` are the interface and
export at `M.UI_PX` (128), because a rack slot is 94 design units and a face in
the commander strip is 62 — paying the map's size for six themes' worth of unit
art is the difference between one atlas page and two. Both numbers are declared
in `main/theme.lua` and read back out by the importer, never restated in it.

Note the texture profile: `realm.texture_profiles` mipmaps `/main/tiles.atlas`
and `/main/emoji.atlas` **by name**. A profile matches the *generated* texture,
not the source directory, so listing `main/assets/tiles/**` would silently do
nothing.

### Android

The device build is bundled and installed straight from the CLI (`adb` lives at
`~/Library/Android/sdk/platform-tools/adb`, not on PATH):

```bash
JAVA=/Applications/Defold.app/Contents/Resources/packages/jdk-25+36/bin/java
$JAVA -jar ~/Defold/bob-1.13.1.jar --platform armv7-android --architectures arm64-android \
  --archive --bundle-output /tmp/android --variant debug --bundle-format apk build bundle
~/Library/Android/sdk/platform-tools/adb install -r /tmp/android/realm/realm.apk
```

Bob writes `debug.keystore` + `debug.keystore.pass.txt` into the project root on
the first debug bundle; both are gitignored build artifacts.

Useful on-device loop — `print` goes to logcat under the `defold` tag:

```bash
adb shell am force-stop com.dg.realm && adb logcat -c
adb shell monkey -p com.dg.realm -c android.intent.category.LAUNCHER 1
adb logcat -d | grep defold
adb exec-out screencap -p > shot.png       # verify visually
adb shell input swipe 800 1200 300 1000 400   # pan
adb shell input tap 907 2262                  # NEW REALM button
```

`adb shell input` covers taps and swipes, but **multi-touch cannot be injected**
— SELinux denies `sendevent` write access to `/dev/input/event7` even though the
shell user is in the `input` group. That is why gesture recognition is a
separate, testable module rather than inline in the camera script.

### Tests

No unit-test framework is configured. A handful of scripts carry the load, all
exiting non-zero on failure and so working in CI as-is:

`tools/lint_shared.lua` is the first thing to run: it is the only check that
knows `realm/` has to satisfy two different Lua runtimes, and both of the
idioms it bans work perfectly under LuaJIT.

`tools/lint_globals.lua` catches the other class of thing no test can see: a read
of a global that should have been a local. It asks LuaJIT for a bytecode listing
and looks at the `GGET` opcodes, so it is exact rather than a regex guess, and it
ignores *writes* because a Defold script legitimately assigns `init`, `update`
and `on_input` as globals.

```bash
luajit tools/lint_globals.lua         # no stray global reads
sh tools/verify_cross_runtime.sh      # BitOp and arithmetic paths agree
luajit tools/verify_determinism.lua   # a seed reproduces exactly, across processes
luajit tools/test_hex.lua             # the lattice, the continent, the graph it makes
luajit tools/test_sim.lua             # turn resolution, combat, fog of war
luajit tools/test_wire.lua            # client/server wire format round-trips
luajit tools/test_gestures.lua        # pan / pinch / tap recognition
luajit tools/test_playback.lua        # the past, rebuilt from the event log
luajit tools/test_plan.lua            # staged orders survive a send; a turn consumes them
luajit tools/lint_shared.lua          # no idioms gopher-lua miscompiles
luajit tools/play.lua                 # pacing: one full game
luajit tools/sweep.lua                # the economy, over twenty seeds
```

`tools/test_hex.lua` exists because the map rests on two claims that are cheap to
state and expensive to discover wrong: that 238x207 is exactly a flat-top
hexagon's bounding box (get it wrong and the map tiles with gaps nobody can
explain), and that the land is one connected piece (get it wrong and a player is
islanded with no move, several turns into a real game). It checks connectivity by
flooding rather than by trusting the growth that produced it, so it can fail
independently of the thing it is testing.

To check a *runtime* agrees with standalone LuaJIT, compare digests — the game
logs one at startup, and Nakama logs one per generated seed, and both must equal
what `luajit` prints for the same seed. **Seed 424242 gives `111246289`,
confirmed on macOS LuaJIT and on gopher-lua inside Nakama.** Names are hashed, so
touching `realm/names.lua` moves every seed's digest:

```bash
luajit -e 'package.path="./?.lua;"..package.path
  print(require("realm.digest").of(require("realm.generate").build(424242)))'
```

## Architecture

### Where things run

| | |
|---|---|
| `realm/` | Pure Lua generation. Runs on **both** the Defold client (LuaJIT) and the Nakama server (gopher-lua). No engine dependencies. `hex` the lattice, `land` the continent, `terrain` what a tile is made of, `graph` the province carving, `generate` the pipeline, `wire`/`digest` the contract. |
| `main/` | Defold client: rendering, camera, HUD, backend client. |
| `server/modules/` | Nakama entry points. `docker-compose.yml` mounts `./realm` into Nakama's module path, so there is one generator, not two. |
| `tools/` | Offline harnesses and tests, run under `luajit`. |

### Simulation (`realm/sim/`, engine-free)

**The game is being rebuilt from the ground up.** What runs today is the
foundation, not a reduced version of something finished:

- every player has a **seat** and a single **commander**;
- commanders move along the tile graph, and whatever they pass through becomes
  theirs;
- a commander with enough **strength** takes ground somebody else holds; one
  without it stops at the border;
- strength comes back only on ground you hold, fastest at your seat;
- holding enough provinces wins; losing your seat loses, and being the last one
  with a seat also wins.

There is no production, no research and no buildings. Those were built once and
deliberately taken out, because the loop underneath them was never the thing
being tested. What is left to build back: **city upgrades producing unit types →
armies with a shape → a battle you can watch → the turn digest played back on
the map instead of listed.**

Combat was built back first, ahead of the production that will feed it, because
without it the game could not end. `tools/play.lua` proved it: the map was fully
carved by turn ~125 and then *nothing changed for 275 turns* - two players sat on
three of the four provinces they needed and neither could take the fourth, because
a border was absolute. With strength, the same seed decides on turn 133 and the
borders move all the way through. **You cannot tune production until you know
what it buys.**

`resolve.turn(realm, state, orders)` advances exactly one turn and returns the
events it produced. It is a pure function of its inputs plus a per-turn seeded
RNG (`rng.stream(seed, "turn:" .. n)`), so a turn replays identically and a whole
game is reconstructable from `(seed, order history)`.

| module | role |
|---|---|
| `rules.lua` | every balance constant, so tuning never means reading logic |
| `tiles.lua` | what kind of place a tile is, derived from its tile |
| `races.lua` | the six playable races, as pure modifier bundles |
| `modifiers.lua` | folds race into the numbers the resolver reads |
| `commanders.lua` | the named officer: rank, portrait, reach and what they lead |
| `units.lua` | the three things a city can put aboard, and what each is for |
| `bots.lua` | what a bot does with its turn, on the server and in the harness |
| `state.lua` | opening state, commanders, and JSON-round-trip repair |
| `path.lua` | Dijkstra along tiles; commanders never move in straight lines |
| `provinces.lua` | who holds a stretch of the realm, and who wins because of it |
| `resolve.lua` | the four phases of a turn |
| `view.lua` | fog of war: detection range, remembered state, per-player projection |

Turn order is **orders → movement → logistics → aftermath → visibility**. It was nine
phases; five of them belonged to production and went with it. Combat lives
inside movement rather than in a phase of its own, because it is what happens
when a commander tries to enter a tile - not a separate step.

#### One commander, one verb

There is exactly one order:

```lua
{ kind = "move", commander = <id>, route = { <tile>, ... } }
```

A route is a list of **wilds**, expanded tile-by-tile by the pathfinder.
With two logins a day, standing orders are what make this playable rather than
tedious. Unclaimed tiles are taken *in passing* and do not stop the commander,
so a route through a chain of empty tiles sweeps them all up.

**A commander stops *before* a border, not on it.** Entering and then being
repelled would mean standing in a tile you do not hold; the route is dropped
rather than held, so a commander never waits on something that may never change.

#### Whether you win is computed; what it costs is simulated

**Resistance has two halves, and both are public:**

```
fortification   the world's own, from its tile + Bastion + seat
army           whoever is standing on it
```

**Two comparisons, and both must hold.** Your siege power against the walls,
your army power against the garrison. Beat both and you take it; fail either
and the commander stops at the border exactly as it did when there was one number,
with the event naming all four figures so the player can see which half turned
them back.

That is the arithmetic a player does *themselves*, on the sheet, before
committing a commander to a turn that resolves twelve hours later - which is why
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
| `rules.defence` | `wilds 2, holding 5, city 9`, plus `seat_defence 12` |
| `rules.commander_strength` | 6 at level one, `+1` a level - see below |
| `rules.exchange_depth` | how drawn-out an even fight is |
| `rules.shield_per_levels` | what a commander's own rank absorbs each exchange |

**An officer's own command is deliberately small.** It is never *spent* - a
battle takes units, and a commander with none loses nothing - so at 12 and `+3` a
level a level-four officer out-fought any city on the map and could do it again
every turn, for ever, at no cost. Six and `+1` keeps a bare commander able to sweep
empty terrain, which is what early expansion is, while a city at 9 needs
something aboard and a seat at 21 needs a real army.

**The commander's shield only ever reduces losses, never the outcome.** That is
what makes it safe to have at all: a veteran wins the same fights and comes out
of them stronger, without making the sheet's arithmetic a lie.

#### Three types, and an army is aimed rather than large

| id | vs fortification | vs army | cost |
|---|---|---|---|
| `escort` | 1 | 1 | 20 |
| `interceptor` | 1 | 3 | 34 |
| `bombard` | 3 | 1 | 34 |

**What they are *called* depends on the theme** — a Freeholder buys an Ox, a
Hound and a Boar; the Barrow buys a Skeleton, a Bat and a Blight. The ids, the
costs and the powers are the same three rows for everyone. See **Themes** under
Rendering.

Small integers on purpose: a player has to be able to add their hold up in their
head and compare it against two numbers on the sheet. Anything larger, or
fractional, and the whole design collapses back into needing a forecast.

**Line dies first**, which is what makes it worth buying - it is the only type
whose job is to still be there when the shooting stops.

**Composition is chosen at embarkation**, not fixed per city. A city holds
generic berths; the mix is picked when a commander loads, which is when the player
already knows what they are marching at. Fixing it per city would be more
strategic on paper and miserable in practice: with three orders a turn, "my
Siege is nine tiles from the fortress" is a logistics puzzle rather than a
decision.

Two consequences worth keeping:

- **A seat needs a veteran.** `seat_defence` puts a seat above a fresh
  commander's entire ceiling, so eliminating a player takes an officer who has been
  winning - not an opening rush.
- **Strength does not come back on its own.** It is bought - see the economy
  below - which is what stops a deep raid running for ever and what makes the
  trip home mean something.

**A defeated commander is broken, not killed** (`commanders.demote`): thrown back
to its seat at zero strength and stripped of a rank. With one commander each, an
officer that could be removed from the board would end a player's game on a
single turn, and everyone would stop committing.

**Battles are the only source of experience**, worth the resistance overcome - so
a city is worth more than open country without any table having to say so.

**An empty batch is meaningful.** It is how a player says "I am done this turn",
which is what lets a turn resolve early once everyone has said it.

#### Three kinds of place

Every tile carries a **terrain**, a **biome**, a **feature** and a habitability
flag, all public map data. `tiles.lua` turns those into three kinds of place:

| kind | derived from |
|---|---|
| **city** | `habitable` |
| **holding** | any feature but `none` |
| **wilds** | everything else - open country |

**A holding is exactly a tile with a feature**, and nothing else. The star map
also promoted energetic star classes, which meant a holding could exist with
nothing drawn to say why. Here the feature *is* drawn - old ruins, a mine, a
shrine, a barrow, a wild gate, a gem seam - so the glyph is the reason, and a
player can price a conquest on the far side of the map by looking at it.

None of them currently produce anything beyond gold - the distinction is what
seats are placed on, what counts towards a province, **what it costs to take**
(see `tiles.defence`), and what city upgrades are priced against.
`profile.industry` and `profile.science` come off the terrain and feature tables
in `realm/terrain.lua`, which is where all the per-kind numbers live; there is
no second copy in the simulation.

**The terrain mix is fixed by ranking, not by thresholds.**
`terrain.classify` takes a tile's *rank* in the map's elevation and moisture
fields - its position in the sorted order, in [0,1) - rather than the raw noise.
So `> 0.88` means "the top 12% of the continent by height" and reads as the
fraction it actually is. That is not cosmetic: fractal noise is a sum of uniforms
and clusters hard around 0.5, so an absolute threshold of 0.72 is nearly two
standard deviations out and picked 3.6% of the map rather than the ~25% it looks
like. The first pass shipped 8 mountains on a 220-tile map for exactly that
reason. Ranking also makes the mix identical on every seed while leaving *where*
the mountains are entirely to the noise - the same trade `realm/land.lua` makes
to get an exact land count.

**Biome is a climate, and the order of the tests is the whole tuning.** Blight
first (deadlands are a scar, not a climate, and can appear anywhere), then the
ice caps by latitude, then a hot-and-arid desert belt, then merely dry, then
greenlands for the rest. Each test only sees what the ones above it did not
claim, so a loose early threshold starves everything below - `sandlands` at
`warmth > 0.68 and moisture < 0.40` took 40% of the continent and left drylands
with the scraps. The shipped mix is roughly 48% greenlands, 18% drylands, 18%
sandlands, 10% deadlands, 7% icelands.

**The generator guarantees a city floor** (`config.city_fraction`).
Habitability is a per-tile roll, and the per-terrain chances in
`realm/terrain.lua` are deliberately tuned to average *just under* the floor, so
the floor always binds and every seed gets the same number of cities - which is
what the economy sweep priced against. Letting the roll win instead gave 28%, or
62 cities where the prices assume 44. What the roll still decides is *which*
tiles they are.

#### The economy: one currency, and one thing it cannot buy

**Gold is fungible; units are not.** A tile pays gold each turn, scaled by
the tile's own `industry` — a number the generator has computed since it was
written and nothing read until now. Units accumulate *only* at cities, up to
`city_stock_cap`, and become strength *only* where a commander is standing. So
wealth alone never wins a front: it converts to force at a city, and somebody
has to walk there.

| | pays | builds |
|---|---|---|
| wilds | **nothing** | — |
| holding | by `industry`, ~2 | — |
| city | by `industry`, ~3 | only what it has dwellings for |
| a seat, on top | `rules.seat_yield` | |

**Road pays nothing, because the map had already decided that.**
`provinces.lua:31` counts only cities and holdings towards victory, so a
wilds was already terrain for the purpose of *winning* and still wages for
the purpose of *paying*. Walking a commander down an empty chain was income for
the rest of the game, in a design whose whole point is that "tiles owned" is a
poor measure. Cities are towns, holdings are mines, the tile between them is
road.

It began as a pure redistribution — wilds were 45% of the tiles and 22%
of the income, and moving that onto the other two left whole-realm income
within a percent of where it was. **The sweep then took a third of it away**,
and the game got faster. See the pricing sweep below: every sink in this design
is capped, so income beyond what the sinks can absorb is not wealth, it is a
number going up.

**The seat's bonus is what makes the opening work.** With road paying
nothing, a player who has taken two tiles and a stretch of tile earns almost
what they earned on turn one, and the seat is the only thing anyone is
guaranteed to hold. It is a shape rather than a decision — the generator places
the seat, so there is nothing to choose; the version with a choice in it is a
building that pays, and there is no room for one at four slots.

**A bot values ground at what it pays**, not from a table of its own:
`bots.lua`'s `score` calls `tiles.yield` directly, so a bot follows the
economy automatically whenever it is retuned and there is no parallel ranking to
drift. It deliberately ignores the seat bonus — a bot cannot take a seat
and keep it paying, and pricing one as though it could would aim commanders at the
target they are least able to hold. This had to land *with* the rate change:
until a bot knows road is worthless, every number `play.lua` produces is a bot
playing the old economy.

**Availability accumulates whether or not you visit, and does not decay.** A
distant city is not wasted production - it is a reason to march. That is
lifted straight from Heroes of Might and Magic, along with the shape that makes
it a decision at all: **you have to pay for what is available.** Without the
cost, collecting is a chore rather than a choice, and you always take
everything.

#### The garrison: two complements, and only one of them is yours yet

A city carries two, and they are not the same thing:

| | |
|---|---|
| `available` | what the dwellings have made and nobody has paid for, per type, to each dwelling's cap |
| `garrison` | what you bought. Sits here until a commander carries it away |

**Buying belongs to the city, not to a commander.** What is bought goes into the
garrison and waits, so a player spends the turn they have the money and collects
whenever somebody can get there. Before this, arming needed an officer standing
on the spot at the moment of purchase - which with three dwellings in three
places is three tours to synchronise with a purse.

**Buying and transferring cost no order** (`rules.order_cost`). An order is
something that *happens somewhere*: moving a commander, raising a building,
raising an officer. Buying is spending, and a transfer is a commander rearranging
what is already yours at a place it is already standing. Charging for a purchase
was right while one went straight into a hold; it stopped being right the moment
purchases went into the city, because charging an empire act means a rich
player banks gold they cannot convert - which is precisely the failure
buildings were introduced to fix, one level down.

**A transfer carries a target hold, not a delta.** Whatever the commander should
have aboard when the turn is over; the resolver works out which way each type
moves. A delta would be wrong the moment anything else touched either side first
- a purchase landing the same turn, a battle on the way in - and this way the
client only ever states the thing the player chose. Buying settles before
transferring, so a purchase and a collection are one turn's work.

**The garrison defends**, folding into the `army` half of the two comparisons
that already exist rather than adding a concept. Production used to defend the
world holding it and had to be taken out, because defence accumulated for free
while an attacker carried theirs across the realm. A garrison is not that: it
is bought, so every unit standing on a world is a unit not in a commander's hold
and the trade pays for itself.

**But being bought was not enough, and that is why there is a cap.**
`rules.garrison_cap` exists because the two sides are not symmetrical: an
attacker's power is bounded by `commander_units` - no amount of wealth brings more
than a hold - while a defender's was bounded by nothing. Measured, uncapped:
**three seeds in ten never decided at all**, territory bit-identical from turn
800 to 900, two players sitting on three of the four provinces they needed. The
same freeze combat was built to end, wearing a receipt. Capped at what one
commander carries, all ten decide again.

**What was ready scatters; what was built stands.** A city that changed hands
handing its conqueror an instant army would pay for taking it twice over, so
`available` is emptied and the garrison dies in the fight that took the world.
The dwellings do not: they are the prize.

#### Pricing it: `tools/sweep.lua`

One variant per process, because the modules are cached and mutating `rules` in
place leaks into every later run in the same VM. Overrides are assignments -
`rules.garrison_cap=8`, `foundry.every=2`, `rules.gold_yield.city=3` - and
what it reports is deliberately more than how long a game takes:

    decided 20/20  median 125  range 71-191  first fight 30  idle 415  built 122
    raised: berths 767  interceptor_bay 675  foundry 585  bastion 325  admiralty 103

**`idle` is the number that found everything.** It is the gold a surviving
player is still holding when the game ends, and at the shipped prices it was
**8,316** - fifty turns of income nobody could spend. Every sink here is capped
(four slots, six in a garrison, two of a type ready), so past a point the
economy simply stopped being a decision.

What the sweep established, in order:

- **Money was never the constraint; throughput was.** Halving every dwelling
  price moved the median the *wrong* way (181 → 167) and pushed idle gold to
  8,800. Raising the stockpile cap did nothing either. Only the cadence moved
  it: `every = 1` on all three took the median to 128 and idle to 2,500.
- **That reverses an older rule** which said every-turn production never
  decides. True of a pooled stock every city got free; not true once
  production is gated behind a building bought with an order and a slot.
- **Then income came down 38%**, and the game got *faster* again — 125, with
  idle at 415. Money running out is what keeps the economy a decision all game.
- **Two prices I expected to be wrong were not.** The Admiralty is reachable —
  players finish with a median of two to three commanders against a ceiling of
  four — and Bastion gets built. Doubling `bastion_defence` made games *slower*
  and left more gold idle, so 8 is not a placeholder.
- **The four-slot cap does bind.** Five slots is ~9 turns faster with less idle
  gold. Keeping four is a deliberate cost, now a measured one.
- **The commander ceiling earns its place.** Capping at two rather than four cost
  9 turns and doubled idle gold — parallel officers are how an empire spends.

Twenty seeds, every player count. "before the sweep" is the prices as first
shipped, "after" is what the sweep set them to, and "hex" is those same prices on
the new substrate — **nothing in `rules.lua` moved between the last two columns**:

| | 2p | 3p | 4p | 6p |
|---|---|---|---|---|
| before the sweep | 93 | 127 | 181 | 217 |
| after the sweep | 92 | 129 | 125 | 170 |
| **on the hex map** | **73.5** | **100.5** | **93.5** | **147.5** |
| idle before | 1313 | 4133 | 8316 | 6308 |
| idle after | 213 | 308 | 415 | 602 |
| **idle, hex** | **203** | **191** | **174** | **351** |

All twenty decide at every count, on both substrates.

**Games are about 25% shorter on the hex map, and the cause is connectivity
rather than economy.** A pruned Delaunay tile network was tuned to a mean degree
of 2.9; a hex lattice gives every inland tile six neighbours and comes out at
~5.0. Commanders manoeuvre far more freely, fronts are wider, and ground changes
hands sooner. Idle gold came down with it, which is the healthy direction — the
economy is still a decision all game rather than a number going up.

Nothing was retuned to compensate, deliberately: the substrate swap was meant to
leave the game underneath alone, and 93 turns at two a day is still six weeks of
real time. If it ever wants slowing, the honest levers are the map's size and
`commander_steps`, not the prices the sweep established.

**Rank sets where a commander starts, not what they can carry.** `base_strength`
is the officer's own command and where a broken one reforms; `max_units` is what
they can lead on top of it, and it is generous. Capping the *total* at the rank
base walled the game shut - a fresh commander could not cover a defended city,
so could never win the battle that would have promoted them, so never got any
stronger. Every game froze with two players on three of the four provinces they
needed and full purses they could not spend.

**Stock deliberately does not defend the city holding it.** It did, and it
nearly doubled what a city cost to take, which re-froze the map that combat
had just unfrozen: defence accumulated for free while an attacker had to carry
theirs across the realm. Fortifying will be a choice a player makes, not
something that happens to a world nobody visited.

**A commander buys where it *ends* the turn**, so a march onto one of your own
cities and an embarkation there are one turn's work. The RPC supersedes per
*kind* for that reason - a resupply that superseded the march would leave the
commander buying where it already stood.

The numbers were measured, not guessed (`tools/play.lua`):

| | median 4-player game |
|---|---|
| stock cap 4, every 2 turns | 283 turns |
| **stock cap 6, every 2 turns** | **190 turns** |
| stock cap 4 or 6, *every* turn | never decides |

Making stock accrue every turn is worse than either: a front where both sides
refit as fast as they can spend never moves.

#### Buildings: four slots, five things, and they do not stack

A city **specialises**, so the decision is spatial rather than numeric: this
one makes escorts, that one is where officers come from, the one on the frontier
is a fortress. You give up exactly one, and where the city sits decides which.

| | | |
|---|---|---|
| **Berths** | 60 | Escorts accumulate here |
| **Interceptor Bay** | 140 | Interceptors accumulate here |
| **Foundry** | 160 | Bombards accumulate here |
| **Bastion** | 100 | flat resistance, and arms nobody |
| **Admiralty** | 220 | another commander allowed, and the place to raise them |

**A city makes only what it has dwellings for.** There is no base production:
a world you have just taken pays gold, counts towards its province and is
somewhere to stand, but has no shipyard until you put one there. That is what
makes the four slots the whole decision rather than a bonus on top of one — and
because **buildings live on the tile**, a city changes hands with everything
built on it. Somebody else's developed arsenal is a target worth marching on,
which is the first time the map has had a reason to want a *particular* world
that was not a province tick or a seat.

**A seat opens with Berths standing.** A player who cannot arm at all until
they have saved the price of a dwelling has no opening — they watch a number
climb for several turns and do nothing.

Slots went from two to four with the dwellings: two was right when a building
was a multiplier on production that happened anyway, and would have meant a
city could make one thing *or* be anything else.

**Buildings need no commander present.** Raising one is an empire's decision, not
an errand, and requiring an officer to stand there would make the whole economy
hostage to one commander's touring speed. It is also the sink that absorbs a large
empire's surplus, which units alone never could - cities produce at a fixed
rate however rich you are, so before buildings a hundred-tile empire banked
tens of thousands it could not spend.

**A Bastion is the only way a world gets harder to take.** Production used to
defend the city holding it, which meant a world nobody had visited fortified
itself for free; fortifying is now something a player chooses and pays for.

**Commanders: one, plus one per Admiralty, to a ceiling of four.** The ceiling is a
rule rather than a layout accident - the commander strip is a row of faces, not
a list, and stops being readable past four. A second commander is the answer to the
touring problem: parallel collection, parallel fronts.

Buildings and recruitment settle in the **logistics** phase, after movement, so a
city taken this turn can be built on this turn - and a build on a city *lost*
this turn is refused rather than quietly enriching whoever took it.

#### Seats

`pick_seats` places every player on a city with at least
`rules.seat_neighbours` more within `rules.seat_hops` tiles, then spreads
them by farthest-point sampling. A player who spawns on a barren headland, or
next door to a rival, has lost at generation rather than in play.

A seat is currently only a spawn and a losing condition - **hold it or you
are out** - and is the one place a player will build once upgrades exist.

#### Commanders

A commander is a named officer with a rank, a face and a speed. The name and the
portrait are most of the point: a piece a player is attached to is worth more
than a token. Everything derives from `level`, so state carries only a level and
an experience total.

**Battles award experience**, worth the resistance overcome. Rank buys reach
*and* weight, so a veteran covers more tiles a turn and can crack a seat a
fresh officer cannot.

**Movement is whole tiles.** A commander crosses `rules.commander_steps` tiles a
turn and always ends the turn *at* a tile.

It used to be a speed - 95 world units a turn along tiles varying from roughly
60 to 200 - and the problem was not the arithmetic but that **the number the rule
depended on was invisible.** Lane length was never drawn, never stated and could
not be eyeballed, so "when does Kess arrive?" had no answer a player could work
out, in a game whose whole point is planning two logins ahead. A step is
countable off the map: a four-tile route takes four turns.

**On a lattice that property is free rather than imposed.** All six neighbours
are `sqrt(3) * hex_size` away, so there is no length left to vary and nothing for
a weighted search to weigh - which is why `path.find` is a plain breadth-first
walk with no tiebreak. What the star map gave up to get countable movement, the
hex map simply has.

**Rank buys reach rather than pace** (`rules.steps_at_rank`): a Commodore covers
two tiles a turn, a Grand Admiral three, and a race with a mobility bonus adds a
whole extra one. Fractions of a step would be exactly the invisible arithmetic
this replaced.

**Determinism in the pathfinder comes from the frontier order**, not from a
tiebreak. `realm.adjacency` is sorted ascending when it is built, so neighbours
are always visited in the same order and the same route is found every time, on
every runtime.

**Terrain does not cost movement.** Mountains and forest are drawn, so a varied
cost would for the first time be *legible* rather than invisible arithmetic - it
is the one thing the lattice newly makes possible. It is deliberately not taken:
it would reprice `commander_steps`, `steps_at_rank` and every pacing number the
sweep established, and the substrate swap was meant to leave the game underneath
alone. The route detours are real without it - a march around a bay runs up to
ten tiles longer than the straight-line distance.

#### Detection is a range

Each *source* sees a distance of its own: a tile you hold reaches
`base + race`, a commander barely past itself. The visible set is the union,
computed as a relaxation rather than a plain breadth-first walk, because the
widest source has to win wherever two overlap.

**Rival commanders are visible where you have eyes.** Their rank and heading show;
their orders do not.

#### Bots

`realm/sim/bots.lua` is engine-free like the rest of the simulation, so the
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
  bot already holds, because a commander turned back has wasted the trip.

It is a plain function rather than a behaviour tree. The game has one verb, so
the whole decision is "which tile next", and a tree there is ceremony around
an `if`. When a bot has to weigh expanding against defending against raiding
against building, that is the moment to reach for one - and to vet it against
the gopher-lua traps first.

#### Provinces are the objective

The map is deliberately far bigger than any one player will touch. With one
commander each and two hundred tiles, most of the realm is scenery - and that
is the intent. What it means is that "tiles owned" is a poor objective: it
counts the empty road a commander walked down alongside the world they fought for.

So the unit of contest is the **province** the generator already carves: a named,
contiguous stretch of a dozen or so tiles, of which only the cities and
holdings count. A player holds a province by holding **more than half** of what is
worth holding in it, and the game is won by holding
`rules.victory_province_fraction` of all provinces.

Nothing about control is stored. It is a pure function of who owns what, so it
is recomputed rather than tracked.

#### Pacing

`tools/play.lua` plays a full game with a commander-per-player AI. On the default
map four players carve it up and one wins around turn 130–150 — about two months
at two turns a day. `tools/sweep.lua` is the broader instrument: twenty seeds, any
player count, reporting how many games decided, the median length, how much
gold a survivor is still sitting on, and what got built. See the table under
**Pricing it** above for what it says on the hex map.

It is also where the losing-player problem is visible: an AI boxed in early
finishes with a tenth of the map and no way back.

### The game (server-authoritative, asynchronous)

2-10 players compete for the realm. Turns resolve on a schedule, players issue
orders between them, and the map is public while state is fogged.

RPCs in `server/modules/game_rpc.lua`:

One order became four. `game.orders` takes `move`, `resupply`, `build` and
`recruit`; a commander may carry one move and one resupply in a turn, and a city
one build. A `resupply` carries a **mix**, not a count - and both the RPC's
cleaning pass and `catch_up`'s rebuild put it through `units.normalise`, because
this is the third time a widened order shape has been silently flattened by a
`tonumber` in one of those two places.

**A turn is worth only `rules.orders_per_turn` of them.** Not a safety limit - a
scarcity. With four commanders and a dozen cities there is always more worth
doing than three orders allow, so a turn is a choice about what matters most
rather than a round of housekeeping.

It works at three because **a route is a standing order**: a commander given
somewhere to go keeps going, for as many turns as it takes, at no further cost.
An order is what it costs to *change* a plan, not to maintain one.

Three things make it a decision rather than a wall:

- **Revising is free.** Superseding runs before the budget, so re-routing a
  commander or changing which building a city gets costs nothing extra - it is
  the same decision, changed.
- **An order can be taken back** before it is sent (`store.plan_remove`, and the
  `x` beside each line in the order bar). Taking one back is as much a decision
  as making one when a turn only holds a few.
- **The count is stated, not implied.** The bar reads "1 of 3 orders used"; a
  budget the player has to work out for themselves is not one they can spend.

`rules.order_cost` is a table rather than a rule buried in the resolver, so
making a kind free is one edit. Resupply is deliberately not free: a commander
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
{ kind = "move", commander, route }
```

The RPC checks *shape* only, and supersedes rather than appends: a second order
for the same commander replaces the first, so the array's position never carries
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
games      / <id>          tile-owned   lobby, schedule, roster
game_state / <id>          tile-owned   the simulation state
game_events/ <id>:<turn>   tile-owned   one turn's events
game_orders/ <id>:<turn>   per-user       that player's orders
```

Everything is tile-owned except orders, so a player cannot read another
player's pending moves straight from storage.

**Sim state is repaired on read** (`state.normalise`). It round-trips as JSON,
and while dense arrays survive, `knowledge[player]` is keyed by tile id and
*sparse*, so it returns with string keys. Indexing it with a number would then
silently miss and every player's fog memory would look empty after each turn.

**The repair has to match the shape it is repairing.** This one coerced each
entry with `tonumber(entry) or 0`, which was correct when memory was `id -> turn`
and quietly flattened every record to the number zero once `view.remember`
started storing `{ turn, owner, seat_of }`. The function written to *stop* fog
memory being wiped on every read was the thing wiping it, and `view.project`
crashed outright the first time a player remembered somewhere they could no
longer see. Nothing offline caught it: under LuaJIT the crash needs a remembered
tile that is not also currently visible, which the tests happened not to
produce. It was found by playing a game through the real RPCs.

For the same reason `view.project` keys tiles by **string** id: a Lua table
with sparse integer keys encodes ambiguously, and the client must be able to
tell which tile each entry describes.

### Backend (Nakama)

```bash
docker compose up -d          # postgres + nakama
docker compose logs -f nakama
docker compose down
```

Console at http://127.0.0.1:7351 (`admin` / `password`), client API on 7350.

The client authenticates with a random per-install device id (`main/device_id.lua`,
persisted via `sys.save`) and calls the `realm.get` RPC, which returns the map
in the wire format defined by `realm/wire.lua` — a contract shared by both
sides, so there is no encoder/decoder pair to drift. Only what cannot be derived
is transmitted (~40 KB); colours, labels, adjacency, borders and bounds are
recomputed on arrival from the same tables the generator used.

Set `realm.use_server = 0` in game.project to run fully offline, or
`realm.nakama_debug = 1` to trace requests — note that prints the session
token, so leave it off otherwise.

**Testing against a physical device**: the phone's `127.0.0.1` is the phone, so
forward the port over USB rather than changing the host:

```bash
adb reverse tcp:7350 tcp:7350
```

**Server-side generation is ~0.6 s for an uncached seed**, then instant (results
are memoised per seed, per runtime VM). It used to be 4-6 s, and the difference is
the substrate: Poisson-disc sampling and a Delaunay triangulation are what cost
that, and a lattice needs neither. Nothing was micro-optimised; the work simply
stopped existing. The same map takes ~5 ms on LuaJIT.

The wire payload came down with it — **~25 KB, from ~40 KB** — because a lattice
has no arbitrary connections to transmit. See `realm/wire.lua`.

### Six things that will bite you on the Nakama runtime

Nakama's Lua is gopher-lua, not LuaJIT, and differs in ways that fail *silently*:

1. **`a, b = b, a` is miscompiled.** The multiple-assignment swap is evaluated
   sequentially, so both names end up with the second value. This turned every
   reordered edge in `delaunay.edges` into a self-loop — a third of the tile
   graph — while the client was perfectly fine. `tools/lint_shared.lua` fails
   the build if the idiom reappears in `realm/`. Use an explicit temporary.
2. **There is no `bit` library.** `realm/rng.lua` detects this and falls back to
   an arithmetic implementation that produces bit-identical results. Without it
   the generator cannot load at all.
3. **`rpc_func`, not `rpc_func2`.** The latter sends the payload as a `?payload=`
   query parameter, which Nakama 3.27 delivers to the RPC as an empty string.
   The server then defaults the seed and serves the same realm every time.
4. **Nakama images before 3.27 are amd64-only** and run under emulation on Apple
   Silicon — ~5x slower again, and it was OOM-killed mid-generation. 3.27+ is
   multi-arch.
5. **A large sparse integer table key can take the whole server out.** The hex
   generator keys its working tables by a single integer folding `(q, r)`. The
   obvious encoding - a generous offset and a matching stride - produces keys in
   the tens of millions. On LuaJIT that is free: a sparse integer key lands in
   the hash part like any other. On gopher-lua it is not. Nakama was **OOM-killed
   before it could answer a single request**, and the symptom is about as hostile
   as it gets: the container simply disappears, the client sees a closed socket
   after 1.6 s, and *nothing is logged anywhere*, because nothing got far enough
   to log it. `realm/hex.lua` now caps `MAX_COORD` at 64, which caps the key at
   16,640, and `hex.field` asserts a radius that would exceed it. If you add
   another coordinate-keyed table, keep the keys small - or use a string.
6. **`goto` and labels are Lua 5.2.** LuaJIT accepts them happily, so a
   `goto continue` passes every offline test in `tools/` and is a coin flip on a
   5.1 runtime. Nothing in the test suite could catch it — the editor's language
   server, also configured for 5.1, was what reported it. `lint_shared.lua` now
   fails on `goto` and on `::label::` in `realm/` for the same reason it fails
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
- **A stream label is a frozen salt, not a name.** `rng.stream(seed, label)`
  derives the stream from the *string*, so renaming a label silently reshuffles
  every map ever generated from every seed. The vocabulary rename walked straight
  into this: `"regions"` -> `"provinces"` and `"capitals"` -> `"seats"` moved the
  province carving and the seat placement on every seed, in a commit whose whole
  claim was that it changed no behaviour. Both are pinned back to their original
  strings with a note in `realm/generate.lua`, which is what let the rename be
  *proved* behaviour-free: recomputing the digest with the old salt reproduces
  the pre-rename value exactly. **Treat these strings like wire-format
  constants.** The digest's own salt (`"realm:"`) was changed deliberately, and
  it is the only reason the recorded constant moved.
- **`rng.stream(seed, label)`** gives each subsystem its own derived stream, so
  adding or reordering a subsystem cannot shift the numbers every *other*
  subsystem sees.
- **Never iterate a hash table with `pairs` where the order affects output.**
  Lua's `pairs` order is unspecified. Anywhere a set has to become a sequence
  (`graph.province_adjacency`, `tools/dump.lua`), the keys are sorted first.
- **Seeds must stay below 2^24.** `go.property` numbers are 32-bit floats, so
  larger integers do not round-trip — 20260823 comes back as 20260824.
  `realm.script` floors and wraps the incoming property for this reason.
- **There is no transcendental arithmetic left, so nothing is quantised.** The
  spiral density field had to be snapped to a 16-bit ladder because it was built
  from `exp`/`log`/`atan2`, which — unlike `sqrt` — are not required to be
  correctly rounded, and glibc, macOS libm and Android's bionic can disagree in
  the last bit. One flipped accept/reject cascaded into a different realm. The
  hex generator needs only value noise (an integer hash, a lerp and a quintic
  polynomial) and `sqrt`, so the whole class of hazard is gone with the sampler.
  **Do not reintroduce a transcendental without reintroducing the ladder with
  it** — `realm/generate.lua` says so at the top.
- **The digest agrees across runtimes, and that is checked rather than assumed.**
  Seed 424242 gives `111246289` on standalone LuaJIT and in Nakama's gopher-lua;
  the server logs its digest per generated seed, so the two can be compared
  directly.

### Rendering (`main/`)

**The map is two sprite layers and nothing else.**

| layer | source | count | what |
|---|---|---|---|
| ground | `main/tiles.atlas` | ~440 | one hand-drawn hex per land and sea tile |
| glyph | `main/emoji.atlas` | ~95 | a Noto emoji on the places worth holding |

Stock Defold throughout: the builtin `sprite.material`, no custom material, no
shader, no vertex buffer, no per-sprite constant — so the whole world is **two
draw calls, one per atlas, by construction rather than by care**. `main/tile.go`
and `main/place.go` are one sprite apiece; `main/realm.script` spawns them
through two factories and calls `sprite.play_flipbook` with the image name
`main/theme.lua` resolves.

What this replaced: seven mesh components with dynamic vertex buffers built in
Lua, seven materials, six fragment shaders, a Voronoi territory module, a
procedural parchment texture and its generator script. All deleted.

**Sprite z is the draw order** (`Z_GROUND = 0`, `Z_GLYPH = 1`). A whole unit
apart, because *every* glyph must draw above *every* tile, not just the one it
stands on — at equal z a glyph would be covered by whichever neighbouring hex
sorted later.

**The tiling is exact, and that is a measured fact rather than a hope.** A tile
PNG is 238x207, which is precisely the bounding box of a flat-top hexagon of size
119 (`2s` by `sqrt(3)*s` = 238 x 206.1, the artist having rounded up a pixel). So
drawing it `2 * hex_size` wide at the tile's own centre *is* the tessellation.
The transparent corners overlap the neighbour and cost nothing: textures are
premultiplied at build time, so a transparent pixel over an opaque one is an
exact no-op. `tools/test_hex.lua` asserts the geometry, and
`tools/import_tiles.py` refuses a pack that is not that size.

The art's pixel dimensions are declared once, in `main/theme.lua`
(`M.TILE_PX`, `M.GLYPH_PX`), and **both importers assert against them** — the
sprite scale is derived from them (`2 * hex_size / TILE_PX.w`), so a
differently-sized pack fails the import rather than silently rescaling the map.

**Open country gets no glyph.** `theme.emoji_for` returns nil for open country. The
old map drew ✨ on every one only because a bare disc said nothing; the hex
underneath now says it is forest, and drawing a sparkle on top would be saying it
twice. That is also what keeps the glyph layer to ~95 sprites rather than one per
tile.

**Biome is a colour, not a redraw.** The five biome directories in the source
pack have pixel-identical alpha masks and differ only in ground colour
(greenlands `136,184,97`, sandlands `238,209,123`, drylands `166,129,103`,
deadlands `78,82,69`, icelands `185,203,208`). Only the six *ground* types are
imported, in each of the five palettes — 30 images. The pack also draws villages,
cities, keeps, ruins and crystals as tiles; those are places rather than ground,
and the emoji layer already draws them. A drawn city inside the hex under an
emoji city on top of it is two cities.

**One fixed palette for the whole sea** (`theme.SEA_BIOME`), rather than each
stretch of water taking its neighbour's. A coastline that changes colour along
its length reads as a rendering fault rather than as geography.

**Do not jitter the hex geometry.** The instinct is to displace the corners so
the borders look hand-drawn, the way the Voronoi territory module did. The art
already carries a wobbly ink hex outline, and jittering the ground would
desynchronise it from the baked glyph.

**The sprites are built once per seed and then left alone.** `present()` in
`main/realm.script` runs whenever a turn resolves, but only a *different seed*
respawns anything — 571 sprites take about 4 ms, and doing that every ten-second
poll would be the most expensive thing in the project. Two guards, because either
alone would leave the trap set:

- the camera re-frames only when the content extent or centre differs from what
  it has, or when it has never framed anything (`self.framed`);
- `present()` clears the selection only for a genuinely different seed, and
  `load_game` skips the rebuild entirely when neither the seed nor the turn has
  changed.

`main/render/realm.render_script` is down to one `sprite` predicate (the builtin
material's tag is `tile`) plus GUI. **It cannot become the builtin render script**,
and that is the whole reason it still exists: it is the only writer of
`store.screen` — the aspect-derived view space every GUI scene lays out in,
`main/ui.lua` hit-tests against, `main/safearea.lua` converts insets into and
`tools/drive.py` reads — and it builds the world projection from `store.camera`
rather than from a camera component, so visible world width is exactly
`design_width / zoom`. That relationship is what lets the HUD place a label with
`(world_x - cam_x) * zoom + width/2` and have it land on the tile.

**The paper is the clear colour**, set in `game.project [render]`. Not a layer,
not a texture — one setting, and the only backdrop the map has. The parchment
mottle mesh, its generator and the parallax that drifted it are gone.

**Ownership, province borders, fog of war and drop shadows are not drawn yet.**
That is a staging decision and it has a real cost: a player sees terrain but not
who holds it, so the map cannot be played from — the tile sheet's owner dot and
the commander strip are carrying that information alone. It is the first thing to
restore. `knowledge()` and `repaint()` are kept in `main/realm.script` as no-ops
precisely because they are where it comes back, and `store.playback_owners` still
routes through `knowledge()` so a digest replay needs no new handshake.

When it does come back it needs **no shader either**: ownership is a third sprite
per hex from a hex-outline image pre-tinted per player (ten images in the tile
atlas, picked by name), and fog is two more as parchment-coloured scrims. Nothing
needs a tint, a material or a per-sprite constant, so this simplification is not
a debt.

**A name is not scenery.** The map is 220 tiles most of which a player never
touches, and naming them all turns it into a wall of words with the geography
buried underneath. Labels are chosen by **relevance to the player**, rebuilt
whenever what makes a tile relevant changes — the selection, the turn, the
commanders — and never per frame, because it walks every tile and sorts them.

| tier | what |
|---|---|
| selected | what the sheet is describing |
| seat | anyone's |
| commander | where one stands, and everywhere its route goes |
| held | somewhere someone holds, including you |
| frontier | unclaimed, but adjacent to something of yours — where a commander can be sent next |

Everything else is never named. Zoom decides which tiers are admitted, pulled
back rather than pushed out: at a distance you want to know whose ground you are
looking at, not what every hill is called. The budget is a filter (22 at most)
rather than the truncation of a much larger set.

Labels and army markers are **GUI nodes**, pooled: a marker wants to stay a
constant size at every zoom and carry a crisp glyph, which is exactly what the
labels already do. Map labels are held inside the horizontal safe-area insets,
and any name that will not fit on either side of its tile is simply not drawn —
a name sliced by the screen edge is worse than no name.

**An army marker is the officer's own face**, the same portrait the commander
strip carries, so a commander picked off the strip can be found on the map
without reading a label. Four nodes, because the marker carries four things and
a face can only be one of them:

| | |
|---|---|
| the face | *which* officer, from `view.commanders[].portrait` — or, for a rival, `view.contacts[].portrait`, which the sim has put on the wire since contacts existed and nothing drew until now |
| the ring | **whose** it is, in `player_ink` |
| the pip | where it is going: `icon_chevron_right`, just outside the ring, rotated to the heading. A parked army has none |
| the caption | the name and the army power, in the same colour as the ring |

**The ring exists because a portrait cannot be tinted.** The marker used to be a
tinted `icon_warship` — the glyph *was* the player colour — and until the
ownership wash is drawn that tint is the only thing on the map saying whose army
it is. It had to move somewhere, and a face in a coloured ring is the vocabulary
the commander strip already uses.

**The face does not rotate.** The ship it replaced pointed along the tile; a face
turned sideways stops being a face, which is why the heading is a separate pip.
And **route segments are created before the markers** so a marker draws over its
own line — that ordering was the wrong way round and never showed, because a
marker used to be a small glyph with a lot of nothing around it. An opaque disc
with a route drawn across it reads as a fault.

### Zoom, and how much realm you can see at once

**Zoom is three buttons on the right of the map**, under the overview: in, out,
and out-to-the-widest. Before them there was no way to zoom at all — pinch is the
only other route and multi-touch cannot be injected from a workstation, so every
device screenshot ever taken was at the fit zoom.

They are on the *top* right, which costs some thumb reach, because the bottom
right is not a stable place to put anything: the order bar spans the full width
and grows upward as the plan does, and the tile sheet comes up over it. A
control that moves when you stage an order is the problem SEND was kept still to
avoid.

**`ZOOM_OUT_LIMIT` was 2.0, and the hex map is the reason it is 1.15.** On the
star map, seeing the whole thing at once was deliberately impossible: the field
was mostly scenery, the widest useful view was a stretch of provinces rather than
the poster, and a higher floor also kept the smallest an emoji ever rendered
legible. **None of those three still hold.** The ground is drawn art rather than a
dot on a dark field, so it reads far smaller than a glyph did; the coastline is
the single most useful thing on the map and it is a *shape*, so it cannot be read
a fifth of it at a time; and at 2.0 the widest view was about ten hexes across,
which is not a realm, it is a neighbourhood. 1.15 still keeps the whole continent
just out of reach — the map should be somewhere you are standing rather than a
picture you are holding — while showing a stretch of coast and most of a
province.

`ZOOM_MAX` is 3.0, about 240 world units across: two hexes side by side, which is
as close as there is anything to see. It was 9.0 and nothing had ever been there.

Three details, each of which the first run of the buttons found:

- **A button zoom pivots on the selected tile**, if there is one and it is
  somewhere visible; otherwise on the middle of `store.hud_band`. Never the
  middle of the *window*: with a tall sheet up that point is behind a panel, and
  pivoting on something invisible sends everything the player can see rushing off
  the top of the band.
- **The camera eases rather than jumps**, for the same reason `focus` does, and a
  press steps from the *target* rather than the current zoom so an impatient
  double-tap adds up instead of landing mid-glide.
- The widest-view button keeps the player's centre instead of gliding to the
  map's, and it *sets* `user_zoomed`, because the result is still a view the
  player chose.

Opening a game focuses your seat once (`present()` posts `focus` for a new
seed when the view knows one), since the opening frame cannot show everything.

The camera owns the step size and the range; the buttons only say which
direction, so there is one description of how far a press goes.

**The camera clamps against the visible band, not the window.**
`store.hud_band` is what the map can actually be seen through. Without it the map
fits the *window* at fit zoom, the camera is pinned by `clamp_position`, and a
tile under the sheet can never be lifted out.

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
offering a new realm.

### Client screens (Monarch) and UI (Druid)

`main/main.collection` is a bootstrap holding `main/app.script` plus one Monarch
screen proxy per screen. **The empire screen was removed** in the rebuild: with
no production and no research there was nothing on it the map does not already
show, and the commander strip is the roster. The proxies are **embedded instances** with their
`screen_id` set inline, matching Monarch's own example — a `screen_id` override
placed in a separate `.go` file did not take effect, and every screen silently
registered under Monarch's default id (`UNIQUE ID HERE`), so `monarch.show`
found nothing.

| screen | collection | role |
|---|---|---|
| `lobby` | `main/screens/lobby.collection` | list/create/join/start games |
| `map` | `main/screens/map.collection` | the realm view (was the old bootstrap) |
| `report` | `main/screens/report.collection` | turn digest; a **popup** over the map |
| `slot` | `main/screens/slot.collection` | one upgrade slot; a **popup** over the map |
| `buy` | `main/screens/buy.collection` | what to put in an empty berth; a **popup** |

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
| `plan_consumed(turn)` | the turn it was for resolved, so throw it away: re-sending would aim last turn's move at this turn's map, at an army that may not exist |

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
formatted three strings and walked the army list every frame, and nothing else
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
committed route is already in the wire (`view.armies[].route`, expanded by the
resolver). A *staged* order is not: the client only picks a destination, and the
resolver expands it tile by tile when the turn runs.

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
  is sent. They exist to draw a line; the server expands the wilds itself,
  against the map as it will be then.

Route segments are pooled GUI nodes, like the army markers and the labels, for
the same reasons: constant thickness at every zoom, and no vertex buffer to
rebuild when a plan changes.

### The commander strip

A row of faces under the overview bar, one per force in the field, each showing
its strength. Tapping one selects that commander **and glides the camera to
them** - to where they actually are, part way along a tile if they are under
way, so the view lands on the marker rather than behind it.

It is the roster and the way around the map at once. With a cap of four there
are never enough commanders to need a list, and a player thinks in terms of
"where is Kess", not "which tile was that".

The camera **eases** rather than cuts (`focus` in `main/camera.script`): the map
is the one thing the player holds a mental picture of, and a cut leaves them
re-reading the screen to work out what moved. Any touch on the map cancels the
glide - it is theirs again the moment they reach for it.

The strip is rebuilt only when the roster changes, keyed on who is in the field,
where, how strong and which is selected. It has its own Druid instance, because
it is a province that gets rebuilt.

### What moves, and what must not

Two things on the map animate, and the line between them is deliberate.

- **A force under way pulses**; a parked one is still. Position only changes when
  a turn resolves, so without this an army crossing a tile looks exactly like one
  sitting on a world. The heading pip says the same thing a second way, which is
  what keeps it readable at the top of the pulse's breath.
- **A committed route flows** - the nodes slide along their legs toward the
  destination, which is pinned and larger. A staged route does not: it is a plan
  in the bar, not a force in motion.

**Animating the actual position would be a lie.** An army's progress advances one
turn's worth at a time, and where it can be intercepted is decided at the turn
boundary. A marker gliding smoothly between two turns would be showing the player
somewhere the simulation says it never was.

### Keeping up with the turn

**The map polls every ten seconds** (`POLL_SECONDS` in `main/realm.script`)
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
before the order was given, and a commander that cannot beat both halves does not
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
`commander.units` - the live table - so a commander that marched on and loaded at a
city before the turn was serialised left the event reporting the hold it ended
the *turn* with, and the screen unwound its exchanges from the wrong end.

### Watching the turn, not reading it

**The digest plays back on the map.** A list of forty turns is a changelog; what
a player wants after two days away is *where the war moved*, and that is a shape
on a map. Opening a digest replays it: markers walk the tiles they walked,
territory recolours as it changed hands, and a transport bar sits where the
order bar does — play, speed, a scrub track with a tick on every turn that had a
fight, and LOG to read it as a list instead.

**The past is rebuilt, not stored.** The client has never been told who held
what forty turns ago and the server does not keep it — state is one current
record, deliberately. It does not have to: **the event log is reversible.**
`claimed` says a tile was unowned before it and `battle` names who it was
taken from, so winding today's ownership backwards through the digest gives the
ownership at any earlier turn *exactly*. `main/playback.lua` does that and
nothing else; `tools/test_playback.lua` plays a real game, snapshots who owned
what at the start of every turn, and checks the reconstruction against those
snapshots tile by tile.

Three things this needed from elsewhere, and would silently be wrong without:

- **`commander_moved` carries the path actually walked.** A commander crossing its
  own territory changed nothing and so emitted nothing at all, which meant the
  one thing worth watching was the one thing the log did not contain.
- **`contact_moved` is what a rival's march looked like from here** — only the
  part inside your detection range, so an army crosses your border, is watched
  for a tile or two, and is lost again in the dark.
- **`knowledge()` in `main/realm.script` is the single place ownership colour
  is decided**, so overriding it with `store.playback_owners` moves the wash,
  the borders and the tile tints together. Only those two layers are rebuilt per
  step (`repaint`); the nebula, dust, tiles and glow do not depend on ownership,
  and rebuilding six layers to change two would make the transport a slideshow.

**Fog is not rewound with it.** What a player could see forty turns ago is not
in the digest, and dimming half the map to guess at it would hide the very
movement the playback exists to show.

**A replay is the one place a marker may animate between tiles.** The live map
must not: an army gliding along a tile would be claiming a position the
simulation says it never had, and where it can be intercepted is decided at the
turn boundary. In a replay the turn is over, the commander really did cross those
tiles in that order, and the only thing invented is how the seconds were spread
across them.

**It frames what it is showing.** The map opens at the fit zoom where a marker is
four pixels wide, so a playback zooms to `PLAYBACK_ZOOM` and eases the camera to
the average of everywhere something happened that turn — then returns to the
whole map when it ends, because leaving the player zoomed into the last turn's
corner ends every digest somewhere they did not choose to be.

**A digest with nothing in it goes back to being a list.** Forty turns of
"nothing moved" is the changelog this replaced, only slower.

**The transport owns its own Druid province**, so a relayout — a window change, or
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

- **A scrim.** Province names are set large and pale and land exactly where a
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

- **A selected tile must not sit under its own card.** The sheet covers the
  bottom half, so `focus_pending` in the HUD lifts the tile into the visible
  band after the sheet is built - deferred, because how much map is left depends
  on how tall the sheet turned out. It intervenes *only* when the tile would
  otherwise be hidden; moving the map on every selection is its own kind of
  clunky.
- **Aiming hands the screen to the map.** `build_sheet` returns nothing while
  `store.aiming` is set, and the order bar carries the origin and the count
  instead. The sheet used to ask the player to "tap where to send" while
  covering half the destinations.
- **The camera clamps against the visible band, not the window.**
  `store.hud_band` is what the map can actually be seen through. Without it the
  realm fits the *window* at fit zoom, the camera is pinned by
  `clamp_position`, and a tile under the sheet can never be lifted out.

**The tile sheet is a rack of slots, not a document.** It was read top to
bottom - a name, a province, a commander, a sentence of capture arithmetic, a
shipyard of labelled rows with `-  n  +` steppers, a button through to a second
screen, and four upgrade boxes at the very bottom, past 900 units of card with
no scroll behind it. That is a page, and a page on the bottom half of a map is a
page nobody reads. Everything that was a *sentence* has gone.

| in order | and why |
|---|---|
| a colour dot, the name, SEAT, and `X` | whose it is, whether it decides the game, and the way out |
| UPGRADES | four boxes: what this world can be made into |
| SHIPYARD | `garrison_cap` circles: what is standing here |
| COMMANDER | `max_units` circles: what leaves with them |

**The order is the order the decisions happen in**, which is why upgrades moved
from last to first: dwellings decide what there is to buy at all, so a city
with none now has an empty shipyard for a reason the card can see. You buy into
the garrison, so that comes next; you load out of the garrison, so the hold sits
directly under what fills it.

- **Whose it is, before what it is.** The dot is the same mark the map draws
  round the tile, so the two are read the same way and the card needs no
  sentence for the common case. The province line and "Held by X" went with the
  prose: colour already says whose, and what kind of place it is is told by what
  the card offers underneath - a shipyard is a city.
- **"SEAT", not "Your seat".** Whose it is, the dot has already said.
- **A tile that is not yours is a dot, a name and an `X`.** Nothing else. That
  is why `SHEET_MIN` came down from 200 to 120: at 200 a bare tile sat in an
  empty box that read as broken rather than as brief.
- **`X` is the first dismiss gesture the card has ever had.** The sheet
  publishes its own rectangle into `store.hud_zones` and `gestures.lua` latches
  `blocked` on any touch starting inside one, so a tap on the card never reaches
  `pick_tile` and could not deselect. The only way out was a tap on bare map.
- **`SHEET_MAX` has stopped binding.** Three rows of slots is around 530 whatever
  is built, against a 960 cap. It is kept because the clamp costs nothing and
  the camera reads the height either way (`store.hud_band`, which is what stops
  a tall card trapping its own tile).
- **The unit names say what the unit is for.** They were Line, Lance and Siege,
  which mean something only to somebody who already knows the rule. Escort,
  Interceptor and Bombard say which one to buy for what. A hold in storage is
  keyed by id, so `units.normalise` carries the old keys across - without that
  every commander in flight comes back empty, and nobody notices until their army
  has quietly evaporated.

**What this gives up is the two comparisons** - "you need 16 against its
defences, you bring only 6" - which were the one piece of arithmetic a player
does before committing a commander to a turn that resolves twelve hours later.
They are shown nowhere else in the client now. If they come back, the place for
them is the aim flow in the order bar, where that decision is actually being
made, rather than on a card about somewhere you are standing. `draw_halves` and
`best_powers` went with them.

#### Two racks, and the whole city loop between them

A slot is 94 design units - 54 dp, well over the 48 dp floor the rest of the kit
holds to, and it matters more here than anywhere else in the interface because
these are *drag* targets: an off-by-one slot is a wrong army. Six across is
exactly the card's inner width, and the rack wraps at six, so a veteran carrying
nine gets two rows rather than nine smaller circles.

**Both racks show what will be there when the turn resolves**, with an accent
ring on anything that is not there yet - the same vocabulary as a staged order
in the bar. Nothing on the card is a delta the player has to add up.

**Neither rack is city-only.** `resolve.transfers` checks that a commander is
standing on ground its owner holds and nothing else, so a holding with units
left on it is a real place with a real garrison and the card says so. Only
*buying* needs dwellings. The commander rack is drawn only when one of yours is
actually standing here - a commander under way has no rack, because there is
nothing to trade with.

**The commander's face sits on the caption line, not in the leading slot.** The
mock-up put it there and it only works while capacity is exactly six: it is
`commander_units + level - 1`, so a veteran needs nine or ten cells and a face in
the grid spills the rack onto a second row for nothing.

**A tap is the fast path, a drag is the deliberate one.**

| | |
|---|---|
| tap a filled slot | that unit goes to the other rack |
| tap an empty shipyard slot | the buy popup, if this world makes anything |
| drag a filled slot | you say which rack it lands in |

Filling a hold is six taps, which is what stands in for the transfer screen's
TAKE ALL. Both directions go through `stage_transfer`, which takes the hold the
commander should **end the turn with** rather than a delta - so a move reads
whatever is already staged, changes it by one, and states the whole thing again.
An order that asks for the hold the commander already has is dropped rather than
sent, so tapping a unit across and back leaves the plan exactly as it was.

**The gesture is hand-rolled, not a Druid drag component**, for the reason
`ui.install_druid_picking` exists at all: Druid resolves positions against
Defold's *configured* display and this project lays out in a view space of its
own. `build_sheet` records every slot's rectangle into `self.slot_rects` in the
same layout space as the nodes and shifts both together, so there is one
description of where a slot is. **Rectangles, not nodes** - the sheet is rebuilt
on every staged change, and a gesture holding a node reference would be holding
a deleted one by the time it ended. The drag ghost is deliberately *not*
collected by `ui.collect` for the same reason.

It runs before the Druid dispatch in `on_input` and claims the release as well
as the press: a gesture starting on a slot has to pre-empt the upgrade boxes
under it, and a drag that ended on a control must not fire it.

**Buying is a popup, because one slot is one unit.** `main/screens/buy.gui_script`
lists only what this world has a dwelling for - the mapping is on the wire, since
every building declares what it makes - and buys exactly one, then closes. The
rack behind it is already the running total, so the picker needs no count of its
own; the steppers it replaced had to carry one because nothing else on the card
could show it. A row is closed for one of three reasons and says which, because
a disabled control that does not explain itself is indistinguishable from a
broken one.

Buying fills the garrison, so it needs no commander present and spends no order —
the bar reads "0 of 3 orders used" while a purchase is staged, which is the whole
point of it being free. And because buys settle before transfers
(`realm/sim/resolve.lua`), a unit bought this turn can be dragged aboard the
same turn: the rack counts the staged basket as standing here.

**The transfer screen is gone.** Its two columns of steppers were the one place
the whole combat design was visible at once, and the racks are that now - the
same split, on the card, with no screen to open. What went with it is TAKE ALL /
LEAVE ALL, and the tap fast path is the answer to the tap count that argued for
them.

**Upgrades are four boxes, and each one opens a popup.** They were four rows with
a name, a line of what they do and a price - a catalogue on the bottom of the
longest card in the game, which never said the one fact that matters: a city
gets *four* of these, ever. Four boxes say that without a sentence.

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
what it decided, both consumed in the HUD's `update`. `store.buy_popup` /
`store.buy_request` are the same handshake for the shipyard rack.

**A slot that promises a verb has to have one.** Berths, an Interceptor Bay, a
Foundry and a Bastion work by standing there, so their boxes say "built" and
their popup says so; only the Admiralty says "tap to use". Labelling all five the
same and then opening a card that says there is nothing to do is how an
interface loses the word.

**Ordering a commander starts in one place: the round face in the strip.** Tapping
it aims, tapping the same face again cancels - aiming takes the whole map, and a
mode you can only leave by finishing it or by hunting for CANCEL is a mode that
catches people. The sheet's commander row is a statement, not a second way in;
when it was one, tapping a city had to hand the map over instead of opening
its card, which is why **tapping a tile now always opens the sheet unless a
move is being aimed**.

**The map has three interactive layers.** The *tile sheet* is rebuilt whenever
the selection changes, because its content varies enormously — open country you
have never visited is three lines, a developed city is garrison, population,
defence, three installations and a list of armies. *Army markers* are GUI nodes
rather than world geometry: a marker wants to stay a constant size at every zoom
and carry a crisp glyph, which is exactly what the labels already do, and it
avoids rebuilding a vertex buffer whenever an army moves. `store.aiming` is the
one piece of interaction state — set by SEND or by tapping an army, consumed by
the next tap on a tile.

**A name is not scenery.** The map is deliberately two hundred tiles most of
which a player never touches, and naming them all turned it into a wall of words
with the tile graph buried underneath. Labels are chosen by **relevance to the
player**, rebuilt whenever what makes a tile relevant changes - the selection,
the turn, the commanders - and never per frame, because it walks every tile and
sorts them.

| tier | what |
|---|---|
| selected | what the sheet is describing |
| seat | anyone's |
| commander | where one stands, and everywhere its route goes |
| held | somewhere someone holds, including you |
| frontier | unclaimed, but adjacent to something of yours - where a commander can be sent next |

Everything else is never named. Zoom decides which tiers are admitted, pulled
back rather than pushed out: at a distance you want to know whose space you are
looking at, not what every rock is called.

The ranking this replaced was static - city beats holding beats wilds, then
by how brightly the tile was drawn, computed once per realm. It had no idea
which tiles were yours or where your commander stood, so it faithfully named the
prettiest forty tiles and none of the six that mattered. **Colour carries
ownership** now, so whose space it is reads without being read, and the label
budget is a filter (22 at most) rather than the truncation of a much larger set.

**Glyph size still ranks what a tile is for, but the emoji itself is the
cue now.** `tile_half` in `main/realm.script` scales a city at 1.45, an
holding at 1.15, open country at 0.70 and a seat at 1.9, with tile-class
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
Druid instances in one gui script (see the province rule below), so finaling any
one of them made the entire scene deaf, and the surviving instance never
recovered: its own `input_inited` flag was still true, so it never re-posted
`acquire_input_focus`.

The symptom is savage to read, because nothing errors and the *first* few
interactions work. Staging an order rebuilt the tile sheet, which finaled the
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
- **A province that gets rebuilt needs its own Druid instance**, not per-component
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
  when a province is rebuilt within a frame of a button being made in it: a fast
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
  the HUD's tile sheet each own one.
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
outline; `map.font` keeps one, because tile names sit over a nebula and need it.
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

### Themes

**A race is a theme, and a theme is art and names — never numbers.** The six
peoples in `realm/sim/races.lua` were star nations left over from before the map
became a realm; they are Freeholders, the Iron Order, the Barrow, the Circle,
the Free Company and Stonekin now. **The ids did not move** (`terran`, `vorn`,
`ashai`, `kepler`, `cartel`, `silicate`), because renaming them would strand
every stored game and every seat a bot has claimed — read an id as a slot, not
as a name.

| theme | escort | interceptor | bombard | berths / bay / foundry |
|---|---|---|---|---|
| Freeholders | 🐄 Ox | 🐕 Hound | 🐗 Boar | Barn / Kennel / Sty |
| Iron Order | 🛡️ Shield | 🐎 Rider | 🔨 Ram | Barracks / Stables / Smithy |
| The Barrow | ☠️ Skeleton | 🦇 Bat | 🎃 Blight | Crypt / Roost / Blight Pit |
| The Circle | 🧿 Ward | 🧚 Sprite | 🐉 Drake | Sanctum / Grove / Hatchery |
| Free Company | ⚓ Anchor | 🦜 Corsair | 💣 Keg | Shipwright / Crow's Nest / Powder House |
| Stonekin | 🪨 Boulder | 🐐 Goat | 💥 Blast | Quarry / Pasture / Delve |

**The moment a theme changes a cost or a power, the sweep's medians stop
describing the game.** Nothing under `realm/sim/` knows a theme exists: the unit
ids, costs and powers are one table for everyone, and the only sim-side change
the reskin made was `label` and `blurb`.

**The art lives in `main/theme.lua`, keyed by race id.** `realm/sim/races.lua`
is loaded by gopher-lua on Nakama, a server that never draws anything, and its
whole stated purpose is to be a modifier bundle. `theme.lua` is already the one
file `tools/import_emoji.py` parses, `tools/render_map.py` resolves through and
`test_wire.lua` joins against.

Three resolvers, each falling back to the plain catalogue so an unthemed race
draws the bare role rather than nothing: `theme.unit_emoji(race, id)`,
`theme.unit_name(race, spec)` → singular and plural, and
`theme.building_name(race, spec)` → name and blurb.

**A building's blurb is derived, not listed.** A dwelling's is "<what it makes>,
ready to buy.", built from `M.UNIT_NAME` — a second table would be the place the
Barn goes on saying "Escorts" after the Ox was renamed.

**There is only ever one theme on screen**, and `ui.my_race()` is the one place
that decides it. Everything the interface lets a player *act on* is theirs: a
rack you can trade with is a garrison on ground you hold or your own commander's
hold, a card offering an upgrade is your city. So art and names follow the
*viewer* rather than the thing being drawn — and the one place that is not true,
a rival's hold in a battle, is drawn as a wall and a name precisely because you
were never told what was in it. `ui.unit_image`, `ui.unit_name` and
`ui.building_name` bind the viewer's theme so no call site repeats the lookup.

**Two tables must stay flat and two must not.** `tools/import_emoji.py` parses
`M.EMOJI`, `M.UNIT_EMOJI` and `M.FACE_EMOJI` with a regex whose block ends at
the first column-0 `}`, so those are keyed `<race>_<thing>` rather than nested.
`M.UNIT_NAME` and `M.BUILDING_NAME` are nested by race precisely because nothing
parses them.

**The race picker shows a face, not a colour swatch.** A swatch promised
something untrue: a player's colour comes from their *seat*
(`config.player_palette`), not from who they are, so two Freeholders are
different colours. The picker draws `commanders.portrait(1, nil, id)` — the
first officer that player will actually raise.

**Half of each race is still inert**, unchanged by any of this: `modifiers.of`
folds only speed, hops, vision, attack and defence, and `EFFECT_LABEL` — the one
piece of client code that ever rendered a `mods` table into words — is dead in
`main/screens/lobby.gui_script`. **The modifiers are currently invisible to the
player**, who sees a name, a face and a blurb.

### Commander portraits

Forty-eight faces in `main/assets/portraits/`, their own atlas
(`main/portraits.atlas`), drawn by `ui.portrait`. They are **Noto emoji**, from
the same `googlefonts/noto-emoji` release and the same importer as the map's
glyphs, composited onto a disc of `ui.CARD_ALT` at `FACE_FILL` and masked round.

**They used to be seventy-two pieces of pixel art whose licence was never
established**, sorted into races by dominant hue by a `tools/import_portraits.py`
that no longer exists. That was the last thing in the project blocking a
release, and swapping the source closed it: Noto is Apache 2.0, recorded in
`main/assets/portraits/NotoEmoji-LICENSE.txt` beside the art. **A portrait is a
role, not a medium** - it is still the face standing for an officer, and every
id it fills is unchanged, which is why nothing in the simulation, the wire or
`ui.portrait` had to move.

**Eight per theme, and the first four are the ones that matter.** A face is an
officer's number modulo the cast (`commanders.portrait`), a player may raise
four (`rules.commander_cap_max`), so slots 01-04 are the only faces ever on
screen together in the commander strip. Those are picked for silhouette - a hat,
a helmet, a colour - and the near-twins every family of emoji contains
(🧟/🧟‍♀️, 🧙/🧙‍♀️) are parked at 05-08 where they are only reached after the
index has wrapped. `tools/test_wire.lua` fails if a theme repeats a codepoint
inside its first four.

Eight rather than one per surname, because six themes would be 240 images and a
player raises at most four officers. Past eight the index wraps.

Faces are masked to a disc at import and drawn with a ring (`ui.portrait`,
`ui.ring`), so the ring covers the mask's soft edge instead of leaving a pale
halo behind it. `FACE_FILL` is 0.78 rather than 1.0 because an emoji is drawn to
the edges of its own square, and at full size the round mask clips a farmer's
hat and a wizard's staff.

**The order is load-bearing.** A portrait is chosen by the player's race plus
the same index as the surname, so the nth officer a player of a given theme
raises always has both the same name and the same face; reordering a cast in
`M.FACE_EMOJI` silently reassigns every existing commander's portrait.
`MANIFEST.json` alongside the images is what says which codepoint became which
face, and is the only way to see that a reorder moved everyone.

`tools/import_emoji.py` reads `PORTRAITS_PER_RACE` out of
`realm/sim/commanders.lua` and refuses to run unless every theme declares
exactly that many - a theme one short would leave the sim naming an image the
atlas lacks. `tools/test_wire.lua` is the other half: it checks that every id
the sim can name resolves in the atlas. Nothing connects the two but a string,
and `ui.portrait` swallows a missing one on purpose - so a mismatch would
quietly put the whole roster in the fallback face rather than erroring.

There is a fallback from surname to index for records raised before officers
carried a number, without which every one of them shared a single face.

### Safe area### Safe area

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
fit on either side of its tile is simply not drawn: a name sliced by the screen
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
the order controls, and the selected-tile card while it is up — and:

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
kept working. Every scroll province in the game was inert on hardware until the
binding was renamed. `main/camera.script` is unaffected either way: it keys on
`action.touch` being present rather than on the action id.

**A full-screen popup claims input rather than blocking it.** `ui.modal_input`
runs the popup's Druid instance and then returns `true` unconditionally, so the
map and its camera get nothing while the popup is up. The obvious alternative —
a Druid `blocker` covering the screen — also sits in front of the popup's own
scroll provinces and eats their drags.

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
  label with `(world_x - cam_x) * zoom + width/2` and have it land on the tile.

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
- **`bootstrap.render = /main/render/realm.render`** — a custom pipeline. Not for
  blend modes any more (there is one sprite predicate); it is the only writer of
  `store.screen` and it builds the world projection from `store.camera`. See
  Rendering above.
- **`sprite.max_count = 1024`** (default 128) and **`collection.max_instances =
  2048`** (default 1024) — the map is ~440 game objects with a sprite each, plus
  ~95 glyphs. Both defaults are far below that, and the failure is a hard cap
  rather than a slowdown.
- **`android.immersive_mode = 1`** — hides the Android status and navigation
  bars, which otherwise sit on top of the HUD.
- **`android.package = com.dg.realm`** — Defold's default is the placeholder
  `com.example.todo`, which collides with every project that never changed it.
- **`safearea.resize_game_view = 0`** — custom mode; see Safe area above. The
  default shrinks the view and letterboxes the remainder.
- **`graphics.max_font_batches = 512`** (default 128) — the interface interleaves
  text and box nodes heavily, and every text node between two boxes is its own
  batch. Past the limit the font renderer silently *stops drawing*: the
  selected-tile card came up completely blank with nothing in the log but a
  `Fontrenderer: Render object count reached limit` warning. `max_draw_calls` is
  raised alongside it for the same reason.
- **`druid.no_auto_input = 1`** — stops Druid managing input focus. Its
  `final()` posts `release_input_focus` for the whole script, which deafens a
  scene that runs more than one Druid instance. See Druid above.
- **`native_extension.app_manifest = /realm.appmanifest`** — excludes physics
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
python3 tools/drive.py tile "Rigel VI" # where a tile is, in device pixels
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
exactly as the map does. Tile positions are regenerated from the seed under
luajit rather than transmitted, since the realm is a pure function of it.

Working this out by hand first is what makes the point: two reference taps gave a
camera of `(-191.75, 243.29)` at zoom `0.37181` against the true
`(-184.38, 256.88)` at `0.37131`, and every tile tap missed.

**Known limitation:** the element query returns the tile labels and the top bar,
but not the tile sheet's own buttons. `state` and `tapstar` are unaffected -
they do not depend on it - and `click` works for anything it can see.

**A y from `find`/`text` cannot be handed to `tap` unchecked, and the
correction is not a constant.** The bridge measures GUI nodes from a different
origin than the one the render script lays out in, and the discrepancy depends
on the window the editor happened to open. Two runs, same build: at a 1440x1970
framebuffer (720x985 view) every reported y was 985 too large and both axes
needed halving; at 720x1280 - where the window matches the design resolution
exactly - the reported figures were already right. So **calibrate once per
session** rather than trusting a formula: take a `shot`, find one unmistakable
label in it, and compare against what `find` says for the same label. That gives
the scale and the offset for every other tap that session.

`drive.py state` publishes `view_width`, `view_height`, `pixel_width` and
`pixel_height`, which is what makes the scale recoverable; the offset is the
part to measure. Feeding `tap` an uncorrected y puts the press off the bottom of
the screen, where it silently does nothing - which reads exactly like a dead
button, and cost an hour before it was noticed.

`click` resolves the element server-side and mostly lands correctly, but it
matches text by **substring**, so `click START` on the lobby also matches
"Waiting to start" and refuses as ambiguous; `--first` then picks the wrong one.
For a control whose label is a substring of another, compute the pixel and
`tap`.

## File formats

Defold source files (`.collection`, `.go`, `.atlas`, `.gui`, `.sprite`, `.input_binding`, …) are **protobuf text format**, not JSON — `.gitattributes` maps them to JSON5 only so GitHub highlights them. They are hand-editable and diff cleanly; match the existing style (unquoted keys, `key: value`, nested `block { … }`, quoted strings). References inside them are absolute project paths and point at *compiled* artifacts — note the trailing `c` in `main_collection = /main/main.collectionc`.

`.internal/` holds editor session state (port, token, downloaded libs, Lua annotation stubs for the LSP). Never edit it or commit it.

## Known gaps

The game is a foundation being built back up, so most of what is missing is
missing on purpose. These are the things that are *not* on that plan, or that
will bite whoever touches them.

**From the hex pivot, in priority order:**

- **The map does not show who owns what.** Ownership, province borders and fog of
  war were all deferred out of the substrate swap, so a player sees terrain and
  nothing else — the tile sheet's owner dot and the commander strip carry it
  alone, which means the map cannot be played *from*. This is the first thing to
  restore, and it needs no shader: ownership is a hex-outline sprite pre-tinted
  per player (ten images in the tile atlas, picked by name), fog is two
  parchment-coloured scrims. `knowledge()` and `repaint()` in
  `main/realm.script` are kept as no-ops because that is where it goes.
- **Nothing is drawn for a drop shadow**, so the glyphs sit flat on the hexes
  rather than reading as stickers on paper. Same fix shape as above.
- **The code has not been renamed.** The fiction is a medieval realm and the
  modules still say `realm`, `tiles`, `tiles`, `commander`, `province`. It is ~2,200
  identifier occurrences across 58 files, purely mechanical, and it is held back
  as a commit of its own so the full suite plus an unchanged digest is the proof.
  Read `tiles` as tiles.
- **`TILE_LABEL_MIN_ZOOM` and the lowest `LABEL_TIER_ZOOM` entries are stale.**
  They were anchored to the old fit zoom and the floor has moved twice since, so
  they sit below anything reachable — always-on rather than wrong, but they no
  longer describe a range.
- **Two textures, 16.8 MB.** The tile atlas is 2048x1024 with mips (11.2 MB) and
  the emoji atlas 1024x1024 (5.6 MB). Fine today. `realm.texture_profiles` is
  where device compression or a `max_texture_size` cap would go if it ever
  matters, and shipping fewer biomes is the other lever.
- **The continent's coast is partly the growable disc.** About 8 tiles a map sit
  on the boundary of the disc the land is grown inside — a suspiciously circular
  arc in an otherwise ragged coast. A looser disc fixes it and costs sprites,
  monotonically; `realm/config.lua` carries the measured trade. At the shipped
  `field_fill` it is 7.8 tiles for 438 sprites.
- **Terrain does not cost movement.** On a lattice, drawn mountains would make a
  varied step cost *legible* for the first time — the one thing the star map's
  invisible tile lengths could never be. It is deliberately not taken, because it
  would reprice `commander_steps`, `steps_at_rank` and every pacing number the
  sweep established.
- **Water is scenery with no rules attached.** It blocks movement only because it
  is not in the graph. There is no naval movement, no crossing, no ferry — an
  island would be unreachable, which is why the generator grows exactly one
  connected continent and can never produce one.

**Carried over, and unaffected by the pivot:**

- **Only the map wears the theme.** Every GUI screen — lobby, setup, sheet, buy,
  battle, report — is still the dark chrome, deliberately, but the interface
  kit's tokens have never been looked at next to the hex art and a re-theme of
  the chrome is an open project of its own.
- **The battle screen's visual treatment is unresolved.** What is there is the
  *derived* reading: pips that thin out, a list of exchanges, nothing drawn that
  the simulation does not know. The open question is whether it should become
  **representational** instead — formations and movement invented for the screen,
  driven by the real per-exchange numbers but not claiming to be positions the
  sim has. That wants deciding before anything is redrawn.
- **The debug strip in the lobby is a back door, not a feature.** `main/dev.lua`
  gates it on `sys.get_engine_info().is_debug`, so it costs a release build
  nothing — but it should come out in one piece when it goes.
- **Nothing is ever lost at the border.** A commander that cannot beat both halves
  does not attack, so there are no failed assaults — only battles that were not
  started. That keeps the sheet's arithmetic honest but means the map has no
  gambles in it at all.
- **The order allowance is fixed at three and nothing raises it.** It is the
  obvious thing for a fifth building to buy, and the obvious thing to scale with
  empire size; neither exists.
- **The two comparisons are shown nowhere in the client.** "To take it, you need
  16 against its defences — you bring only 6" was on the tile sheet and went
  with the rest of its prose. That arithmetic is the whole of combat and the
  thing a player does before committing a commander to a turn that resolves twelve
  hours later, so this is a real hole. The place for it is the aim flow in the
  order bar, where the decision is being made.
- **A rival commander standing on a tile is no longer named on its card.**
  Their *face* is on the map marker now, which is what the wire always
  intended - but the card still says nothing about them.
- **The marker's heading pip has not been seen on screen.** The face, the
  ring, the caption and a parked marker with no pip are all verified on
  desktop; a commander actually *under way* was not reachable in the
  session that built it, so the chevron's placement and rotation are
  argued rather than observed.
- **Only one commander's rack is shown when two are standing on the same tile.**
- **Half of each race is still inert.** `modifiers.of` folds speed, hops, vision,
  attack and defence; growth, industry, research, capacity and the cost keys are
  read by nothing until production returns.
- **A boxed-in player still has no way back.** Nothing rubber-bands and income is
  linear in territory, so falling behind still compounds.
- **A battle is one comparison, so there is nothing to play back inside it.**
- **The playback shows movement but not the fighting.** A battle recolours the
  tile it happened at and gets a tick on the scrub track; it does not get a
  moment of its own, which is the turn a player would most want to stop on.
- **Existing games from before the pivot are dead.** Their stored state indexes a
  star map that no longer generates, and the wire version has moved to 2. There
  is no migration and there should not be one.
- **Combat is unverified on a device.** The sim, the server and the full RPC
  round trip are covered, and the desktop client has been driven through a
  battle, but the strength badge and the battle rows in the digest have only been
  seen on desktop.
- **The hex map itself is unverified on a device.** It has been driven end to end
  on desktop through the real Nakama — create, start, generate on the server,
  render, resolve a turn, zoom — but `adb` and a real screen have not seen it.
- **`drive.py` cannot see the tile sheet's own buttons.** The bridge's element
  query returns labels, the top bar and a popup's own text, but not the sheet or
  the order bar, so those still have to be tapped by position.
- **The bridge redirects, and the redirect downgrades POST to GET.** On desktop
  the engine service port answers `302` to another port, and the Python client
  follows it with a GET — so every `/input/*` call comes back `405
  method_not_allowed` while `elements` and `screenshot` work fine. Pass `--port`
  the *redirect target* (`lsof -nP -iTCP -sTCP:LISTEN | grep dmengine` lists
  both). In practice: `elements`/`state` on one port, `click`/`tap` on the other.
- **A route can only be set one wilds at a time from the map.**
- **A real two-finger pinch has still never been performed.** The zoom buttons
  cover the range, so this is no longer load-bearing, but `gestures.lua`'s pinch
  path is verified only by `tools/test_gestures.lua`.
- **An army marker's name can land on top of a tile label.** The label pass
  rejects label-on-label overlaps, but markers are a separate pool.
- **A route longer than `ROUTE_POOL` segments draws only its first 64 legs.**
- The safearea extension logs `ERROR:ENGINE: Could not find '@render' socket`
  once at startup on Android. Benign, but noise in every log.
- The turn digest is capped at 40 turns server-side and 140 rows client-side.
- **The tile art's licence is not established, and it is now the only one.** The
  `foundation_tiles` pack ships no licence file, no author and no terms;
  `main/assets/tiles/CREDITS.txt` records that. `main/assets/portraits/` used to
  be on the same footing and no longer is — those faces are Noto under Apache
  2.0. Fine for a prototype, must be resolved before anything ships.

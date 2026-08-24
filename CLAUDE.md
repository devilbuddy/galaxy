# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

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
not the game renderer, but its layer order and colour choices are the spec the
Defold one follows, so it is the right place to try a visual change first.

There is no automated check of the interface itself; it is verified by building
to the device and reading screenshots (`adb exec-out screencap -p > shot.png`).
`tools/make_ui_textures.py` also writes a contact sheet of the glyphs if you want
to eyeball them without a build.

`tools/make_textures.py` regenerates the nebula backdrop in `main/assets/`, and
`tools/make_ui_textures.py` regenerates the interface atlas in
`main/assets/ui/` **and rewrites `main/ui.atlas`**. Re-run whichever applies
after changing a parameter; every PNG in those directories is a build artifact
of its script, not hand-authored art. Adding an interface glyph means adding a
function to the `ICONS` table and re-running — nothing to wire up by hand.

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
luajit tools/test_plan.lua            # staged orders survive a send; a turn consumes them
luajit tools/lint_shared.lua          # no idioms gopher-lua miscompiles
```

To check a *runtime* agrees with standalone LuaJIT, compare digests — the game
logs one at startup, and it must equal what `luajit` prints for the same seed.
Seed 424242 gives `1720409762` on macOS, arm64 Android and standalone LuaJIT:

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

A server-authoritative, asynchronous 4X for 2-10 players: discrete turns resolve
on a schedule (typically twice a day), players issue orders between them, and the
star map is public while everything about *state* is fogged.

`resolve.turn(galaxy, state, orders)` advances exactly one turn and returns the
events it produced. It is a pure function of its inputs plus a per-turn seeded
RNG (`rng.stream(seed, "turn:" .. n)`), so a turn replays identically and a whole
game is reconstructable from `(seed, order history)`. That is what lets a
300-turn game be simulated in under a second under LuaJIT while the same code
runs on Nakama's much slower interpreter in production.

| module | role |
|---|---|
| `rules.lua` | every balance constant, so tuning never means reading logic |
| `systems.lua` | what kind of place a system is, and what it can do |
| `buildings.lua` | the three installations, as levels rather than queue items |
| `races.lua` | the six playable races, as pure modifier bundles |
| `tech.lua` | the twelve-technology research tree |
| `modifiers.lua` | folds race + researched tech into the numbers the resolver reads |
| `commanders.lua` | the officer leading a force: rank, experience, what it is worth |
| `regions.lua` | who holds a stretch of the galaxy, and who wins because of it |
| `state.lua` | opening state, fleets, the officer reserve, and JSON-round-trip repair |
| `path.lua` | Dijkstra along lanes; fleets never move in straight lines |
| `resolve.lua` | the nine phases of a turn |
| `view.lua` | fog of war: detection range, remembered state, per-player projection |

Turn order is **directives → growth → industry → research → fleet orders →
resupply → movement → interception → battles → aftermath**.

#### Three kinds of place

Every system already carried a star class, a feature and a habitability flag, all
public map data. `systems.lua` turns those into three *kinds* of place rather
than one kind with different multipliers, which is what gives the map objectives
and terrain instead of two hundred interchangeable things to own:

| kind | derived from | population | buildings | output |
|---|---|---|---|---|
| **colony** | `habitable` | grows to a ceiling | all three | scales with population |
| **outpost** | a productive feature or an energetic class | none | military only | a flat trickle |
| **waypoint** | everything else | none | none | none |

A waypoint producing nothing is the point, not a gap: fleets stop at the first
hostile system, so a barren lane junction is a blockade point worth taking.

**The generator guarantees a colony floor** (`config.colony_fraction`). Habitability
is a per-star roll and on a small map its variance decides the game - the same
120-star setting produced 13 colonies on one seed and 26 on another, and 13 is
not a playable four-player map. The count is topped up deterministically, most
habitable classes first with ties broken by index, so every seed is fair while
*which* worlds are habitable stays driven by the roll. `pick_homes` then places
every player on a colony with at least `home_colony_minimum` more within
`home_colony_hops` lanes, because a player who spawns in a barren arm has lost at
generation rather than in play.

#### Commanders

**A force is an officer and the ships they lead, in one record.** They are named
for the officer ("Admiral Kess", not "3rd Fleet"), carry a level and an
experience total, and everything else about them - rank, what they can lead, how
fast they move, what they are worth in a fight - is derived from those two
numbers, so state stores nothing it can compute (`galaxy/sim/commanders.lua`).

**The cap is the shape of the game, not a balance knob.** A player may field
`rules.commander_cap` of them, so "which fronts am I fighting on" is a decision.
Without it a 400-turn run ends with one empire holding a hundred and sixty
forces and a list nobody can read.

| | |
|---|---|
| rank | promotion is how a level reads on a map. A number is something a player looks up; Captain against Grand Admiral is legible at a glance, and it is the same information |
| command | ships this officer can lead; the rest stays in the garrison, so a veteran is worth more than the sum of their ships |
| speed | **deliberately below a typical lane at level 1**, which is what puts forces in transit where they can be caught |
| tactics | what the *senior* officer present multiplies their side by. A garrison with nobody in command gets nothing, which is what makes stationing one worth doing |

Experience is enemy ships destroyed - a number already on the battle report -
split across the winners by what each brought, so stacking every commander into
one battle promotes the group no faster than fighting it alone.

**A beaten commander is scattered, not killed**: they fall back to a world you
still hold, one rank lighter, and their army is gone. Losing an officer outright
would make one bad battle unrecoverable in a game checked twice a day and would
teach players never to commit. Only a player with nowhere left to fall back to
actually loses them.

**Standing down retires an officer to a reserve**, keeping their rank, and a
launch recalls the most experienced reservist before raising anyone new. A
player choosing which of four fronts to give up must not also lose the rank that
officer spent forty turns earning, or the cap stops being a decision and becomes
a trap.

**A parked commander draws from the garrison they are sitting on** (`resupply`),
up to what they can lead. This is how production reaches the front: parking one
somewhere is the standing instruction "send what you build here", which is the
right shape of decision at two logins a day. It is also what makes a scattered
officer recoverable - without it a beaten commander sat at a refuge with no ships
forever, holding one of the four slots and unable to use it, which froze the game
outright once every player had lost four battles.

**Co-located forces are not consolidated.** They used to be, to keep the list
readable; under a cap the list cannot get long enough to need it, and merging
would quietly destroy an officer for parking next to a colleague.

#### Fleets

**Ships live in one of two places, and the split is the whole point.** A system's
**garrison** is where production accumulates; it defends alongside the world's own
guns and never moves. A **fleet** is a named, persistent force that sits at a
system or partway along a lane, carries a route, and survives arriving somewhere.

Fleets-only was tried first and does not work: production has to land somewhere,
so it creates a fleet wherever there is not one, and a 400-turn run ended with one
empire holding **a hundred and sixty** of them. Making the player create a fleet
deliberately bounds the list to forces they care about, and turns "strip a border
world to mount an attack" into a decision rather than an accident.

Three verbs, because that is what the two gestures on the map need:

| order | effect |
|---|---|
| `launch { at, ships?, route }` | form a fleet out of a garrison and send it |
| `move { fleet, ships?, route }` | redirect one, or detach part of it |
| `garrison { fleet }` | stand a fleet down where it is |

There is no split verb - `move` carries an optional count instead, since
splitting is only ever something done *in order to* send part of a force
somewhere. And **co-located parked fleets consolidate at the end of every turn**,
oldest name surviving: without it the map silts up with arrivals and the list
becomes unusable. The consequence is that two fleets cannot be held apart at one
system, which is why the count rides on the move.

A route is a list of **waypoints**, expanded lane-by-lane by the pathfinder. With
two logins a day, standing orders are what makes this playable rather than
tedious. Unclaimed systems are taken *in passing* and do not stop the fleet, so a
route through a chain of barren waypoints sweeps them all up.

#### Regions are the objective

The map is deliberately far bigger than any one player will touch. With a handful
of commanders and two hundred systems most of the galaxy is scenery, and that is
the intent - which makes "systems owned" a poor objective, since it counts the
empty road a commander walked down alongside the world they fought for.

So the unit of contest is the **region** the generator already carves
(`galaxy/graph.lua`): a named, contiguous stretch of a dozen or so systems, of
which only the colonies and outposts count. Waypoints are road.

- A player holds a region by holding **more than half** of what counts in it. A
  plurality would hand a region to the first player through it while two others
  were still fighting over the worlds that matter; a majority means a region
  changing hands is news.
- A held region **produces more** (`rules.region_output_bonus`), which is what
  makes going back for the last stubborn outpost worth doing instead of leaving
  half-taken regions all over the map.
- Holding `victory_region_fraction` of all regions **wins the game**. Before
  this there was no victory condition at all - players could be eliminated, but
  nothing ever declared a winner.

Nothing about control is stored. It is a pure function of who owns what, so it is
recomputed, and `regions.weights` is memoised on the galaxy the way system
profiles are.

#### One economy axis

A system produces **build points**, which become ships or pay for a building, and
**research**, which is the only thing that pools empire-wide. No second currency,
no upkeep, no logistics: what makes an empire strong is how much ground it holds.
Everything stored is an integer - output and research are fractional once class,
race and technology have scaled them, so each is summed as a float and floored
exactly once per system per turn, which is what lets state survive a JSON round
trip through Nakama storage without a replay drifting.

#### Buildings as levels

A per-system build *queue* would turn this into a chore list: twenty worlds, two
logins a day, every session spent re-checking timers. So a building is a level
raised once and never thought about again - one tap, paid out of that system's own
output over however many turns it takes, then done forever.

| installation | effect | may go on |
|---|---|---|
| **Radar Array** | +1 lane of vision per level, from this system | colony, outpost |
| **Fortress** | +40 static defence per level | colony, outpost |
| **Shipyard** | +35% output per level | colony only |

**People-buildings need a colony; installations do not.** Radar wants to be on the
*frontier*, and a frontier is mostly not colonies - with outposts able to host it
there is almost always somewhere to put a listening post where one is needed.

Buildings **survive capture** intact. Taking a fortified chokepoint is meant to be
a prize, and it then defends its new owner. That self-balances against blitzing,
because capture costs population and both output and defence scale with it: a
freshly taken fortress world is hard to retake and produces almost nothing until
it repopulates.

#### Detection is a range

Each *source* sees a distance of its own: an owned system reaches
`base + radar levels + technology`, a fleet barely past itself. The visible set is
the union, computed as a relaxation rather than a plain breadth-first walk because
the widest source has to win wherever two overlap.

**Enemy fleets are visible where you have eyes.** Their strength and heading show,
their orders do not. A conquest game where an invasion cannot be seen coming is
one where worlds are lost overnight with no way to answer, and a developed border
outpost being worth fighting over is the whole reason radar exists.

#### Combat

A Lanchester-style exchange: the loser is destroyed and the winner keeps the
fraction its margin implies, so a narrow win is expensive and an overwhelming one
nearly free. A defender fights with garrison + stationed fleets + the world's own
guns, and casualties fall on the garrison first, then a stationed fleet - never on
the planet's guns, which are not something that can be shot down. That means
keeping a fleet on a world is worth doing.

**Hostile fleets that end a turn in the same lane fight there.** A deliberate
abstraction: a lane is a narrow corridor, so two hostile forces inside one engage
regardless of where along it they are or which way they point. Modelling the exact
crossing point would need the whole path each fleet swept.

#### Pacing

Still not tuned, and still for the same reason. `tools/play.lua` plays a full game
with a greedy AI; results run from a fortnight to never, and that spread is
dominated by the AI - which never defends, retreats, or concentrates beyond one
frontier - rather than by the rules. Tuning against it would be fitting to noise.
`rules.tech_cost_scale` and `rules.building_cost_scale` are the two pace knobs.

### Generation pipeline (`galaxy/`, engine-free)

`generate.build(seed)` runs these in order; each stage exists to fix a specific
failure of the simpler thing:

1. **`shape`** — a density field: radial bulge + disc, logarithmic spiral arms,
   fBm irregularity. Normalised so every seed peaks at 1.0, otherwise any
   threshold expressed in density units means something different per seed.
2. **`poisson` / `points`** — variable-radius Poisson-disc sampling. Spacing
   goes as `1/sqrt(density)`, which is what makes the core dense and the rim
   thin; density is applied to *spacing*, and only a soft cutoff is applied as
   rejection. `points.generate` solves for the spacing that hits a requested
   star count, so `star_count` in `config.lua` is a real target.
3. **`delaunay`** — Bowyer-Watson triangulation. The reason for Delaunay is
   planarity: no two edges cross, so *any* subset stays non-crossing and the
   pruning below can never produce visually intersecting lanes.
4. **`graph`** — keeps the MST unconditionally (guarantees every star is
   reachable), then adds short-biased extra edges up to a target mean degree.
   Regions grow along the lane graph with **balanced** multi-source expansion:
   plain Dijkstra gives one region 70% of the map, so at each step the smallest
   region takes the cheapest star on its frontier. Region colours come from
   Welsh-Powell graph colouring, so no two bordering regions share a tint.
5. **`names` / `starclass`** — weighted templates over invented and borrowed
   vocabulary, with global uniqueness; classes biased towards exotics near the
   galactic core.

### The game (server-authoritative, asynchronous)

2-10 players compete for the galaxy. Turns resolve on a schedule, players issue
orders between them, and the map is public while state is fogged.

RPCs in `server/modules/game_rpc.lua`:

| rpc | purpose |
|---|---|
| `game.create` | new lobby; rolls a seed, sets turn interval, size and the creator's race |
| `game.list` | open lobbies, **and separately** the caller's own games |
| `game.join` / `game.start` | lobby management; `join` carries the race pick |
| `game.state` | the caller's fogged view plus events since a given turn |
| `game.orders` | submit (and freely revise) orders for the coming turn |

An order is one of five shapes, and `game.orders` replaces the whole batch:

| order | effect |
|---|---|
| `{ kind = "launch",   at, ships?, route }` | form a fleet from a garrison and send it |
| `{ kind = "move",     fleet, ships?, route }` | redirect a fleet, or detach part of it |
| `{ kind = "garrison", fleet }` | stand a fleet down where it is |
| `{ kind = "build",    at, building }` | raise a level (`""` cancels) |
| `{ kind = "research", tech }` | set the research target (`""` clears it) |

The RPC checks *shape* only, and supersedes rather than appends: a second order
for the same fleet, the same world, or a second research directive replaces the
first, so the array's order never carries meaning a client would have to know
about. Whether an order is *legal* depends on state that will have moved on by
the time it resolves, so the resolver decides that and emits an `order_rejected`
event carrying a reason the client can show. Because the batch is replaced
wholesale, the client sends fleet orders, buildings and research together; two
calls would mean the second wiped the first.

**Turns resolve lazily.** There is no scheduler: every RPC first asks whether
turns are due and resolves however many were missed. For a game checked twice a
day that is exactly right, needs neither cron nor Nakama's Go runtime, and
cannot drift. The consequence is that an untouched game does not advance until
somebody touches it. Concurrent resolution is prevented by version-guarded
storage writes — the loser of the race discards its work and re-reads.

Storage layout (Nakama storage; the Lua runtime has **no SQL access**):

```
games      / <id>          system-owned   lobby, schedule, roster
game_state / <id>          system-owned   the simulation state
game_events/ <id>:<turn>   system-owned   one turn's events
game_orders/ <id>:<turn>   per-user       that player's orders
```

Everything is system-owned except orders, so a player cannot read another
player's pending moves straight from storage.

**Sim state is repaired on read** (`normalise_state`). It round-trips as JSON,
and while dense arrays survive, `knowledge[player]` is keyed by star id and
*sparse*, so it returns with string keys. Indexing it with a number would then
silently miss and every player's fog memory would look empty after each turn.

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

Six mesh components, one per layer, each with a dynamic vertex buffer built once
per seed by `main/meshbuild.lua` and uploaded with `resource.set_buffer`. Per-item
colour lives in a **vertex stream**, not a material constant — a per-component
constant would break batching, so this keeps each layer to a single draw call.
The whole map is ~6 draw calls and does no per-frame CPU work except the
parallax backdrop.

**Shapes are drawn procedurally in the fragment shaders, not from sprites.** A
textured quad is only ever as sharp as its texture, and this map zooms to ~19x
the fit scale, where a 64px disc is visibly mushy. Each layer derives its shape
from the UV instead (`main/shaders/`):

| shader | used by | shape |
|---|---|---|
| `disc.fp` | star cores | hard disc, edge antialiased with `fwidth` |
| `dot.fp` | background dust | soft point |
| `glow.fp` | star halos | exponential falloff, zero at the quad edge |
| `wash.fp` | region territory | wide soft falloff |
| `lane.fp` | hyperlanes | solid band, `fwidth`-antialiased edges |
| `mesh.fp` | nebula | the one genuine texture |

Two consequences worth knowing when tuning: the procedural shapes fill the whole
quad where the old textures faded out inside it, so size constants are *not*
interchangeable with the pre-shader values; and `fwidth` needs derivatives,
which is core in GLSL 140 / ES 3.0 (verified on the device's Vulkan backend).

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

`ZOOM_MAX` is 9.0, roughly 19x the fit zoom. At that range a fixed-resolution
backdrop stretched over the world is a smear, so `main/galaxy.script` fades the
nebula and dust out between zoom 0.6 and 2.2, and eases the region wash back to
45%. Fading is done with a `tint` fragment constant set via
`go.set("/backdrop#nebula", "tint", …)` — a mesh material's USER constants are
settable as component properties, which is far cheaper than rebuilding the
vertex buffers every frame.

`main/render/galaxy.render_script` owns the layer order and blend modes, which
together *are* the visual treatment:

    nebula   alpha     dust  additive   wash  alpha
    lanes    alpha     glow  additive   stars alpha    gui alpha

Textures are premultiplied by Defold at build time, so alpha layers use
`ONE / ONE_MINUS_SRC_ALPHA` (not `SRC_ALPHA / ...`) and the shader premultiplies
the vertex colour to match.

### Client screens (Monarch) and UI (Druid)

`main/main.collection` is a bootstrap holding `main/app.script` plus one Monarch
screen proxy per screen. The proxies are **embedded instances** with their
`screen_id` set inline, matching Monarch's own example — a `screen_id` override
placed in a separate `.go` file did not take effect, and every screen silently
registered under Monarch's default id (`UNIQUE ID HERE`), so `monarch.show`
found nothing.

| screen | collection | role |
|---|---|---|
| `lobby` | `main/screens/lobby.collection` | list/create/join/start games |
| `map` | `main/screens/map.collection` | the galaxy view (was the old bootstrap) |
| `report` | `main/screens/report.collection` | turn digest; a **popup** over the map |
| `empire` | `main/screens/empire.collection` | stockpile, research tree, build policy; also a popup |

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

Choices are **staged in `store`, not sent** — `store.orders` holds fleet and
building orders in the exact shape the RPC takes, and `store.pending_research`
holds the technology pick. They all travel with the next SEND, which is what
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

### Keeping up with the turn

**The map polls every ten seconds** (`POLL_SECONDS` in `main/galaxy.script`)
while a game is open. Turns resolve on a schedule measured in hours, so this only
has to be brisk enough that a player watching the screen sees the turn land — and
the request is also what drives the server's lazy resolution, so a polling client
is what makes a game advance at all.

**A turn that lands while the map is open is held, not shown.** A popup must not
drop on top of somebody mid-read, but the digest must not be lost either — and
advancing `seen_turn` on a background poll is exactly how it was being lost: the
next request asks for events *since* that turn, so the server would never send
them again. Turns that resolved while the player watched produced no report,
ever. The digest is now parked in `store.pending_report` with `seen_turn` left
alone, the turn card in the overview goes accent and reads "new — tap to read",
and **opening it is what marks it read**. Nothing is lost if the player never
taps: the poll keeps returning the same window.

**EMPIRE lives at the top right of the overview bar, not the bottom one.** That
card is what a player reads every turn anyway, and the bottom row belongs to
SEND — the action with consequences — plus CANCEL, which only exists while
something is being aimed, so SEND keeps the far right whether or not it is there.

**The map has three interactive layers.** The *system sheet* is rebuilt whenever
the selection changes, because its content varies enormously — a waypoint you
have never visited is three lines, a developed colony is garrison, population,
defence, three installations and a list of fleets. *Fleet markers* are GUI nodes
rather than world geometry: a marker wants to stay a constant size at every zoom
and carry a crisp glyph, which is exactly what the labels already do, and it
avoids rebuilding a vertex buffer whenever a fleet moves. `store.aiming` is the
one piece of interaction state — set by SEND or by tapping a fleet, consumed by
the next tap on a system.

**Star size encodes what a system is for.** `kind_scale` in `main/galaxy.script`
draws a colony half again as large and a waypoint at little over half, which is
the only cue on the map for the difference. Note it has to be declared *above*
the mesh builders — a Lua local is not visible to a function defined before it,
and putting it lower silently broke every build with `attempt to call global
'kind_scale'`.

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
  instance and *then* deletes the nodes, in that order: a component whose node is
  already gone throws from its own teardown too. The empire screen's tab body and
  the HUD's system sheet each own one.
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
- **`physics.scale = 0.01`, `physics.gravity_y = -1000`** — inherited from the
  template. Nothing uses physics yet; the world is in pixel units if it ever does.

## File formats

Defold source files (`.collection`, `.go`, `.atlas`, `.gui`, `.sprite`, `.input_binding`, …) are **protobuf text format**, not JSON — `.gitattributes` maps them to JSON5 only so GitHub highlights them. They are hand-editable and diff cleanly; match the existing style (unquoted keys, `key: value`, nested `block { … }`, quoted strings). References inside them are absolute project paths and point at *compiled* artifacts — note the trailing `c` in `main_collection = /main/main.collectionc`.

`.internal/` holds editor session state (port, token, downloaded libs, Lua annotation stubs for the LSP). Never edit it or commit it.

## Known gaps

- **A real two-finger pinch has never been performed.** The recogniser is unit
  tested, and the touch stream is confirmed live on device (`action.touch`
  arrives populated), but Android blocks synthetic multi-touch so the actual
  gesture has only been verified by proxy.
- **There is no way to zoom on a device.** Zoom is pinch-only, and pinch cannot
  be injected, so every device screenshot so far is at the fit zoom where
  panning is clamped to nothing. That also means **panning has never been
  observed working on a device** — the recogniser is unit tested, the tap path
  and every scroll region are confirmed live, but the map pan path is not.
  On-screen zoom controls would fix both at once.
- The safearea extension logs `ERROR:ENGINE: Could not find '@render' socket` once
  at startup on Android. It is benign — the extension reaches for the render
  system before it exists, and in custom mode there is no letterbox for it to
  colour — but it is noise in every log.
- The turn digest is capped at 40 turns server-side and 140 rows client-side. A
  game left to resolve unattended for weeks otherwise produced an event list
  that exhausted the GUI node budget outright.
- **A fleet's route can only be set one waypoint at a time from the map.** The
  simulation takes a full waypoint list and expands it lane by lane, and the
  order shape and tests cover it, but the only gesture wired up is "tap a
  destination". Multi-leg campaigns need a way to chain taps.
- **Interception is now reachable but still unobserved in play.**
  `commander_speed` is deliberately below a typical lane, so a green officer
  spends turns in transit where they can be caught - but whether it happens
  depends on which lanes the generator drew, and the test still slows commanders
  right down to keep itself about the rule rather than about the seed.
- **The pacing of the region victory is untuned.** `victory_region_fraction` is
  0.5 and the greedy AI in `tools/play.lua` gets a leader to two thirds of what
  it needs over 400 turns without ever closing it out. That is the AI, which
  never defends, retreats or concentrates - tuning the fraction against it would
  be fitting to noise, the same reason `tech_cost_scale` is still where it is.
- **Armies are still one number.** The commander layer is in; unit composition -
  the thing that would make "you brought the wrong army" a real decision - is
  not. Combat remains a Lanchester exchange on a single strength value.
- **A commander's rank and command capacity are drawn but unverified on a
  device.** The rows are in the HUD sheet and the empire screen and both compile,
  but the only game on the test device resolves a turn every few seconds, so a
  staged launch is consumed before it can be sent, and a fresh game cannot be
  started solo (the server requires two players).
- Nothing renders a fleet's *route* on the map. You can see where a fleet is and
  the sheet says where it is bound, but not the path it will take.

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

```bash
sh tools/verify_cross_runtime.sh      # BitOp and arithmetic paths agree
luajit tools/verify_determinism.lua   # a seed reproduces exactly, across processes
luajit tools/test_sim.lua             # turn resolution, combat, fog of war
luajit tools/test_wire.lua            # client/server wire format round-trips
luajit tools/test_gestures.lua        # pan / pinch / tap recognition
luajit tools/lint_shared.lua          # no idioms gopher-lua miscompiles
```

To check a *runtime* agrees with standalone LuaJIT, compare digests — the game
logs one at startup, and it must equal what `luajit` prints for the same seed.
Seed 424242 gives `1975657186` on macOS, arm64 Android and standalone LuaJIT:

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
on a schedule (typically twice a day), players issue orders between them, and
the star map is public while everything about *state* is fogged.

`resolve.turn(galaxy, state, orders)` advances exactly one turn and returns the
events it produced. It is a pure function of its inputs plus a per-turn seeded
RNG (`rng.stream(seed, "turn:" .. n)`), so a turn replays identically and a
whole game is reconstructable from `(seed, order history)`. That is what lets a
400-turn game be simulated in 210 ms under LuaJIT while the same code runs on
Nakama's much slower interpreter in production.

| module | role |
|---|---|
| `rules.lua` | every balance constant, so tuning never means reading logic |
| `races.lua` | the six playable races, as pure modifier bundles |
| `tech.lua` | the sixteen-technology research tree |
| `resources.lua` | the three resources, and which systems produce them |
| `modifiers.lua` | folds race + researched tech into the numbers the resolver reads |
| `state.lua` | opening state, home systems, and JSON-round-trip repair |
| `path.lua` | Dijkstra along lanes; fleets never move in straight lines |
| `resolve.lua` | the ten phases of a turn |
| `view.lua` | fog of war: visibility, remembered state, per-player projection |

Turn order is **directives → growth → income → upkeep → research → build →
departures → movement → battles → freighter arrivals → aftermath**. Fleets stop
at the first hostile system on their path, so lanes can be blockaded.

**Three resources, and each system is good at a different one.** Metal builds
hulls, fuel runs them, research buys technology. A system's *base* yield is a
pure function of its star class and feature — both already public map data — so
a player can judge somewhere they have never visited and plan a conquest around
it; what stays private is the population multiplying it. A pulsar is a terrible
place to live and an excellent place to refuel; precursor ruins are worth a war.

**Metal and fuel are deliberately separate levers.** Metal decides how fast you
can build a navy, fuel decides how big a one you can keep — warships cost metal
to lay down and fuel every turn thereafter. Fuel upkeep, not the population cap,
is what actually bounds fleet size in play; a ten-system empire earns roughly
enough fuel for six hundred warships, well under what its population allows. Run
out and the fleet attrits *and the yards stop*: without that second half, a
starved empire spends its entire metal income replacing ships that die the same
turn, which reads as a broken economy rather than as a fleet that is too big.

**A race is a bundle of modifiers, and nothing branches on one.** Races and the
tech tree contribute to the same effect table, `modifiers.of(player)` folds them
into one set of numbers, and the resolver reads only that. Adding a race or a
technology is a data change. `modifiers.of(nil)` is the *neutral* baseline, not
the default race — the tests compare against it.

**Research is one standing decision, not a per-turn allocation.** Research
accumulates in the stockpile and the chosen technology is bought the moment it
is affordable. That suits a game checked twice a day far better than a slider
would. `rules.tech_cost_scale` is the single knob for how long the tree takes to
walk: the list prices in `tech.lua` fix the *ratio* between technologies, that
fixes the pace. At 1.0 the greedy AI in `tools/play.lua` finished the entire
tree by turn 25 — a fortnight — which made the back half of it scenery. At the
current 9.0 a first technology lands around turn 11-30, half the tree between
turn 40 and 170, and only a runaway leader ever finishes it. The scale applies
to the **research** half of a cost only: metal is also the only thing that buys
ships, and multiplying it too made the full tree cost about as much metal as a
whole game produces, so the tree stopped being a parallel investment and became
an alternative to having a navy. All those figures come from that AI, so treat
them as an order of magnitude, not a target.

**Trade routes are the one thing that is not territory.** A `trade` order sends
freighters between two systems you own; on arrival they open a route that pays
every turn, scaled by its length and the population at both ends. Routes pay in
research and fuel and never in metal, so hulls always have to come out of ground
you hold and a commercial empire still needs one. Lose either endpoint and the
route dissolves — the freighters fall back to whichever end is still yours, or
are gone.

**Fog of war** is geometry-public, state-private. Players always see stars,
lanes, names and yields; they see *ownership, population and ships* only within
their vision radius of anything they hold, and wherever they have a fleet. The
radius is one lane by default and two with Survey Network, which is the
difference between seeing a build-up and seeing it arrive. What was once seen is
remembered and returned stamped with the turn it was observed, so the map does
not flicker as scouts move. `view.project` omits unseen systems entirely rather
than sending zeroes, so the payload cannot leak strength by its shape. Enemy
fleets in transit are never visible, and freighter counts are reported only for
systems you own.

**Fleet strength is also capped by population** (`fleet_cap_per_pop`). This
predates the fuel economy and is now a backstop rather than the live constraint.
It stays because removing it reopens the failure it was added for: without any
ceiling, garrisons grow without bound, defence compounds and the map freezes
into a permanent stalemate by about turn 75, which is exactly what
`tools/play.lua` showed.

**Pacing is still not tuned.** `tools/play.lua` plays a full game with a greedy
AI and reports turns-to-decision. Results still range from a fortnight to never
across seeds and galaxy sizes, and that spread is dominated by the AI (which
never defends, retreats, trades, or concentrates beyond one frontier) rather
than by the rules. Tuning the constants against it would be fitting to noise.
The reliable fix for an async game is probably a fixed end turn plus a score,
which is also what the BBS-era games did.

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

An order is one of four shapes, and `game.orders` replaces the whole batch:

| order | effect |
|---|---|
| `{ kind = "move", from, to, ships }` | send warships |
| `{ kind = "trade", from, to, ships }` | send freighters to open a route |
| `{ kind = "research", tech }` | set the research target (`""` clears it) |
| `{ kind = "policy", warship_share }` | split new production, 0..1 |

The RPC checks *shape* only — at most one research and one policy directive per
batch, the rest passed through. Whether an order is legal depends on state that
will have moved on by the time it resolves, so the resolver decides that and
emits an `order_rejected` event carrying a reason the client can show. Because
the batch is replaced wholesale, the client sends movement and standing choices
together; two calls would mean the second wiped the first.

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

### Four things that will bite you on the Nakama runtime

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

`app.script` authenticates once and then shows the lobby, so moving between
screens never re-authenticates. Screens are handed their parameters through
Monarch (`monarch.data`), which is how the map learns which game to load.

Screens are built in code rather than laid out in `.gui` files (`main/ui.lua`
holds the shared look). Their content is dynamic — a list of games, a list of
turn events, a research tree — so most of it would be script-created anyway.

Choices made on the empire screen are **staged in `store`, not sent**
(`pending_research`, `pending_share`). They travel with the next SEND alongside
the movement orders, which is what keeps the one-batch-replaces-everything rule
above safe, and lets the player revise the whole turn freely until it resolves.
The HUD counts them so the button does not say NO ORDERS while something is
waiting.

**Druid needs three adaptations here, all in `main/ui.lua`:**

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

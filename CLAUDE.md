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

Not a git repository.

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
/Applications/Defold.app/Contents/Resources/packages/jdk-25+36/bin/java -jar ~/Defold/bob.jar resolve build
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

`tools/make_textures.py` regenerates everything in `main/assets/` procedurally.
Re-run it after changing any texture parameter; the PNGs are build artifacts of
that script, not hand-authored art.

### Android

The device build is bundled and installed straight from the CLI (`adb` lives at
`~/Library/Android/sdk/platform-tools/adb`, not on PATH):

```bash
JAVA=/Applications/Defold.app/Contents/Resources/packages/jdk-25+36/bin/java
$JAVA -jar ~/Defold/bob.jar --platform armv7-android --architectures arm64-android \
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
luajit tools/test_wire.lua            # client/server wire format round-trips
luajit tools/test_gestures.lua        # pan / pinch / tap recognition
luajit tools/lint_shared.lua          # no idioms gopher-lua miscompiles
```

To check a *runtime* agrees with standalone LuaJIT, compare digests — the game
logs one at startup, and it must equal what `luajit` prints for the same seed.
Seed 424242 gives `4037449860` on macOS, arm64 Android and standalone LuaJIT:

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

The camera declines gestures starting inside the HUD bar rather than relying on
winning the input-focus race with the GUI, since acquisition order between them
is not guaranteed.

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
- The label font is the Defold builtin `vera_mo_bd.ttf`, which is monospace.
  Swapping in a proportional TTF is a one-line change in `main/fonts/map.font`
  and would look considerably closer to a real 4X map.

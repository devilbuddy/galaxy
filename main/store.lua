--- Shared state between the map scripts.
--
-- `script.shared_state` is enabled in game.project, so every script runs in one
-- Lua state and a required module is a single shared instance. That makes a
-- module the natural place for state the camera, the map and the HUD all need,
-- and avoids fanning the same data out over messages every frame.

local M = {}

-- The generated galaxy (see galaxy/generate.lua for its shape).
M.galaxy = nil

-- The view, published by the render script: the design width from
-- game.project, with the height derived from the framebuffer's real aspect
-- ratio. This is the space the world projection and GUI nodes live in.
--
-- Touch coordinates do NOT arrive in this space: Defold always normalises them
-- to the configured display size. `input_scale_*` converts between the two, so
-- always route action.x/action.y through M.input_point() rather than using
-- them raw. `framebuffer_*` is the real pixel size and is informational.
M.screen = {
	width = 720, height = 1280,
	input_scale_x = 1, input_scale_y = 1,
	framebuffer_width = 720, framebuffer_height = 1280,
}

-- Live camera state, written by main/camera.script and read by the render
-- script to build the projection.
--
-- `zoom_min` is the fit-the-whole-galaxy floor and `zoom_max` the ceiling; both
-- are published because the HUD's zoom buttons have to know when they have run
-- out of range - a control that still animates a press but does nothing is
-- indistinguishable from a broken one.
M.camera = { x = 0, y = 0, zoom = 1, zoom_min = 1, zoom_max = 1 }

-- Currently selected star index, or nil.
M.selected = nil

-- "server" or "local": where the current galaxy came from.
M.source = nil

-- The active game's id, and the player's projected view of it.
M.game_id = nil
M.game_view = nil
M.game = nil
-- Highest turn whose events the player has already been shown.
M.seen_turn = 0

-- The server's clock, sampled on each state response and advanced locally
-- between them. Used for the "next turn in ..." countdown; the device clock
-- cannot be trusted to agree with the server's.
M.now_estimate = 0

-- Orders staged locally for the coming turn, in the shape the server takes
-- (see server/modules/game_rpc.lua). They are only sent when the player
-- submits, so a plan can be revised freely.
--
-- **The plan is not cleared by sending it.** `game.orders` replaces the whole
-- batch server-side, so a client that forgot what it had sent would wipe it the
-- moment the player added one more order and pressed SEND again - the second
-- batch, carrying only the new order, would supersede the first. The plan
-- therefore lives until the turn it was for resolves, and every send transmits
-- all of it.
M.orders = {}

-- The turn the staged plan is aimed at, and what the server last accepted.
-- `sent_signature` is compared against the live signature to decide whether
-- anything is unsent, which is more reliable than a dirty flag every call site
-- that stages an order has to remember to set.
M.orders_turn = nil
M.sent_signature = nil
M.sent_turn = nil

-- The turn this player has declared themselves done with, or nil. Submitting is
-- what ends a turn - the game resolves as soon as everyone has - so this is
-- what stops the button offering to end a turn that has already been ended.
M.turn_ended = nil

-- Set by the in-game menu when the player confirms they are leaving. The HUD
-- acts on it: a popup cannot navigate from its own teardown (see
-- main/screens/menu.gui_script).
M.leave_requested = nil

-- A colony's upgrade slot the player has just tapped, and what the popup that
-- opens over it should offer: `{ at = <system>, slot = <n>, building = <id or
-- nil> }`. An empty slot picks something to build; a full one is the way to
-- whatever that building lets you do.
--
-- The HUD shows the popup and the popup answers back through `slot_request`,
-- because staging an order means spending the turn's allowance and only the
-- HUD knows how much is left - and because a popup cannot act after Monarch
-- has begun tearing it down.
M.slot_popup = nil
M.slot_request = nil

-- A colony and the captain standing on it, when the player has asked to move
-- units between them: `{ at = <system>, captain = <id> }`. Shown by the HUD
-- for the same reason as the slot popup - a screen cannot open one from inside
-- the region Monarch is part way through tearing down.
M.transfer_popup = nil
M.transfer_request = nil

-- A colony and the captain standing on it, when the player has asked to move
-- units between them: `{ at = <system>, captain = <id> }`. Shown by the HUD for
-- the same reason as the slot popup - a screen cannot open one from inside the
-- region Monarch is part way through tearing down.

-- A turn digest that arrived on a background poll rather than on arrival at the
-- map. Held rather than shown, because a popup must not land on top of a player
-- who is in the middle of reading the map; the overview offers it instead.
M.pending_report = nil

-- Playback: the digest being watched rather than read (main/playback.lua).
--
-- `playback_owners` is who held what at the turn currently being replayed,
-- keyed by system id. When it is set the map draws *that* instead of today -
-- `knowledge()` in main/galaxy.script is the single place ownership colour is
-- decided, so overriding it there recolours the wash, the borders and the
-- stars together. `playback_revision` is bumped whenever the step changes, and
-- is what tells the map to repaint; nil owners means the playback is over and
-- the live view is correct again.
-- Set alongside `pending_report` when the digest should be opened immediately
-- rather than offered on the turn card - which is the case on arrival at the
-- map, where there is nobody mid-read to interrupt. Whether it opens as a
-- playback or as a list is the HUD's decision, so both routes hand over the
-- same way.
M.report_now = false

M.playback_owners = nil
M.playback_revision = 0
M.playback_active = false

-- Currently selected captain id, or nil. A captain and a system can be selected
-- at once: the system is what the card describes, the captain is what an order
-- will move.
M.selected_captain = nil

-- What the next tap on the map will do, or nil for "just look":
--   { kind = "move", captain = <id> }
-- Set by the system sheet, consumed by the next system tap.
M.aiming = nil

-- Transient status line for the HUD ("connecting...", "requesting galaxy...").
M.status = nil

-- The band of the screen the map is actually visible in: everything between the
-- bottom chrome and the top chrome, in view units. The camera clamps against
-- this rather than the window, because the window includes several hundred
-- units of panel the player cannot see the galaxy through.
M.hud_band = { floor = 0, ceiling = 0 }

-- Height of the bottom HUD bar, in view units. Used only to frame the map in
-- the space the player can actually see; see hud_zones for input.
M.hud_bar_height = 0

-- Device safe-area insets, in view units (main/safearea.lua). The world draws
-- edge to edge - there are no letterbox bars - so these exist purely to keep
-- chrome out from under a notch or a gesture strip. Every screen adds them to
-- its outer margin, and re-lays-out when `safe_revision` changes, because the
-- platform does not know the real values for the first couple of frames.
M.safe = { top = 0, bottom = 0, left = 0, right = 0 }
M.safe_revision = 0

-- Rectangles {x0, y0, x1, y1} in view space that the HUD occupies. The camera
-- declines any gesture starting inside one, rather than relying on winning the
-- input-focus race with the GUI - acquisition order between them is not
-- guaranteed. The HUD republishes these whenever it lays out.
M.hud_zones = {}

-- Bumped whenever a new galaxy is generated, so the HUD can notice.
M.revision = 0

--- How many orders the plan holds. A build or a recruit counts as one: they are
--- directives like any other and the player is owed an accurate count.
function M.plan_count()
	return #M.orders
end

--- What the plan costs against the turn's allowance.
--
-- The costs come from the server (`rates.order_cost`) rather than a copy here,
-- because the server enforces the same table and a client counting differently
-- would let a player stage a plan that arrives shorter than it left.
local function order_cost(order)
	local rates = (M.game_view and M.game_view.rates) or {}
	local costs = rates.order_cost or {}
	return costs[order.kind] or 1
end

function M.plan_spent()
	local spent = 0
	for i = 1, #M.orders do spent = spent + order_cost(M.orders[i]) end
	return spent
end

function M.plan_allowance()
	local rates = (M.game_view and M.game_view.rates) or {}
	return rates.orders_per_turn or 0
end

--- Is there room for one more of this kind?
function M.plan_has_room(kind)
	local allowance = M.plan_allowance()
	if allowance <= 0 then return true end
	local rates = (M.game_view and M.game_view.rates) or {}
	local cost = (rates.order_cost or {})[kind] or 1
	return M.plan_spent() + cost <= allowance
end

--- Drop one staged order. **Before it is sent, and only before**: once a batch
--- is with the server, removing an order means sending the whole plan again
--- without it, which `plan_signature` already notices.
function M.plan_remove(index)
	if index < 1 or index > #M.orders then return false end
	table.remove(M.orders, index)
	if #M.orders == 0 then M.orders_turn = nil end
	return true
end

--- A stable string for the plan as it stands.
--
-- Compared against `sent_signature` to answer "is there anything unsent?". The
-- array order is the client's own and deterministic, so a plain concatenation
-- is enough; nothing here has to survive a round trip.
function M.plan_signature()
	local parts = {}
	for i = 1, #M.orders do
		local o = M.orders[i]
		local route = ""
		if type(o.route) == "table" then
			for k = 1, #o.route do route = route .. "," .. tostring(o.route[k]) end
		end
		-- The hold is a table, so it has to be spelled out: `tostring` on one
		-- gives an address, which is stable enough within a session and
		-- meaningless across a rebuild - a signature that changes for no reason
		-- reads as "unsent" for ever.
		local mix = ""
		if type(o.units) == "table" then
			local rates = (M.game_view and M.game_view.units) or {}
			for k = 1, #rates do
				mix = mix .. "," .. rates[k].id .. "=" .. tostring(o.units[rates[k].id] or 0)
			end
		elseif o.units then
			mix = tostring(o.units)
		end
		parts[#parts + 1] = table.concat({
			tostring(o.kind), tostring(o.captain), route,
			mix, tostring(o.at or ""), tostring(o.building or ""),
		}, ":")
	end
	return table.concat(parts, "|")
end

--- Remember that the server took the plan exactly as it stands.
function M.plan_sent(turn)
	M.sent_signature = M.plan_signature()
	M.sent_turn = turn
	M.orders_turn = turn
end

--- Throw the plan away, because the turn it was aimed at has resolved.
--
-- Re-sending it would point last turn's move at this turn's map, and the
-- fleet it named may no longer exist.
function M.plan_consumed(turn)
	if not M.orders_turn or turn < M.orders_turn then return false end
	M.orders = {}
	M.orders_turn = nil
	M.turn_ended = nil
	M.sent_signature = nil
	M.sent_turn = nil
	return true
end

--- Convert a touch/mouse position into view space.
function M.input_point(x, y)
	local s = M.screen
	return x * s.input_scale_x, y * s.input_scale_y
end

return M

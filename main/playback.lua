--- The turn digest, as something to watch rather than read.
--
-- A list of forty turns is a changelog. What a player actually wants to know
-- after two days away is *where the war moved*, and that is a shape on a map,
-- not a sentence. This turns the digest into a timeline the map can play:
-- who was where at the start of each turn, which lanes they crossed, and what
-- changed hands when.
--
-- **Engine-free on purpose**, like `main/gestures.lua`. The interesting part is
-- the reconstruction below, it is fiddly, and it is exactly the sort of thing
-- that is impossible to check by watching an animation - so it is a module with
-- a test (`tools/test_playback.lua`) rather than logic inside a gui script.
--
-- ### Where the past comes from
--
-- The client knows who holds what *now*. It has never been told who held what
-- forty turns ago, and the server does not store it - state is a single current
-- record, deliberately.
--
-- It does not have to be told. **The event log is reversible.** `claimed` says
-- a system was unowned before it, and `battle` names the player it was taken
-- from, so winding the log backwards from today's ownership gives the ownership
-- at any earlier turn exactly. Nothing is inferred and nothing is approximated;
-- if an event is missing from the digest the reconstruction is wrong in exactly
-- the places the player could not see anyway.

local M = {}

-- What a turn's events can do to who owns a system, and how to undo it.
local OWNERSHIP_KINDS = { claimed = true, battle = true }

--- Bucket events by turn, keeping the order within each turn.
--
-- The resolver emits a turn's events in the order they happened, which is what
-- makes the undo below exact: two changes to the same system in one turn have
-- to be reversed in the opposite order to the one they were applied in.
local function by_turn(events)
	local turns, order = {}, {}
	for i = 1, #events do
		local event = events[i]
		local turn = event.turn or 0
		if not turns[turn] then
			turns[turn] = {}
			order[#order + 1] = turn
		end
		local bucket = turns[turn]
		bucket[#bucket + 1] = event
	end
	table.sort(order)
	return turns, order
end

--- Who a system belonged to before `event` happened.
local function owner_before(event)
	if event.kind == "claimed" then return 0 end
	-- A battle names the player it was taken from, which is the whole reason
	-- `against` is on the wire.
	return event.against or 0
end

local function copy(owners)
	local out = {}
	for id, who in pairs(owners) do out[id] = who end
	return out
end

--- Apply one turn's ownership changes to a snapshot, in order.
local function apply_turn(owners, bucket)
	local changes = {}
	for i = 1, #bucket do
		local event = bucket[i]
		if OWNERSHIP_KINDS[event.kind] and event.at then
			local was = owners[event.at] or 0
			owners[event.at] = event.player
			changes[#changes + 1] = {
				at = event.at, to = event.player, from = was,
				battle = event.kind == "battle" or nil,
			}
		end
	end
	return changes
end

--- Undo one turn's ownership changes, newest first.
local function undo_turn(owners, bucket)
	for i = #bucket, 1, -1 do
		local event = bucket[i]
		if OWNERSHIP_KINDS[event.kind] and event.at then
			owners[event.at] = owner_before(event)
		end
	end
end

--- Build a timeline from a digest.
--
-- @param digest   { events = , you = , turn = } as `game.state` returns it
-- @param systems  the projection's systems table, keyed by *string* id
-- @return array of steps oldest first, each:
--   turn      the turn number
--   owners    who held what at the **start** of the turn, keyed by number
--   moves     { player, captain, from, path, mine } - a march, or a sighting
--   changes   { at, to, from, battle } - ownership, in the order it happened
--   battles   { at, player, against, resistance }
--   quiet     true when nothing at all happened
function M.build(digest, systems)
	local events = (digest and digest.events) or {}
	local turns, order = by_turn(events)

	-- Today's ownership, as numbers. `view.project` keys systems by string id
	-- because sparse integer keys do not survive JSON; everything below indexes
	-- by number, so this is the one place that conversion happens.
	local owners = {}
	for key, sys in pairs(systems or {}) do
		local id = tonumber(key)
		if id then owners[id] = sys.owner or 0 end
	end

	-- Wind backwards to the start of the earliest turn in the digest, keeping
	-- the snapshot each turn opened with on the way past.
	local opening = {}
	for i = #order, 1, -1 do
		local turn = order[i]
		undo_turn(owners, turns[turn])
		opening[turn] = copy(owners)
	end

	local steps = {}
	for i = 1, #order do
		local turn = order[i]
		local bucket = turns[turn]
		local step = {
			turn = turn,
			owners = opening[turn],
			moves = {},
			battles = {},
		}
		-- The turn's own events, kept whole so the caller can write a caption
		-- from them. Star names live on the galaxy and region names on the
		-- events; neither belongs in here.
		step.events = bucket
		for k = 1, #bucket do
			local e = bucket[k]
			if e.kind == "captain_moved" or e.kind == "contact_moved" then
				step.moves[#step.moves + 1] = {
					player = e.player, captain = e.captain,
					from = e.from, path = e.path or {},
					name = e.name, rank = e.rank,
					-- A sighting is drawn like a march but is not one: it is
					-- only the part that was in range, so it starts and stops
					-- in mid-air on purpose.
					mine = e.kind == "captain_moved",
				}
			elseif e.kind == "battle" then
				step.battles[#step.battles + 1] = {
					at = e.at, player = e.player, against = e.against,
					resistance = e.resistance, name = e.name,
				}
			end
		end
		-- Applied to a copy, because `step.owners` *is* `opening[turn]` and has
		-- to keep saying what the map looked like before the turn played. The
		-- next step's snapshot is the state after.
		step.changes = apply_turn(copy(opening[turn] or {}), bucket)
		step.quiet = #step.moves == 0 and #step.changes == 0
		steps[#steps + 1] = step
	end

	-- The state the map should be left in: today's, which is where the live
	-- view already is. Rebuilding it here rather than trusting the caller to
	-- have kept a copy means a playback always ends somewhere true.
	local final = copy(opening[order[1]] or {})
	for i = 1, #order do apply_turn(final, turns[order[i]]) end

	return steps, final
end

--- How long a step should be held on screen, in seconds.
--
-- A quiet turn is skipped past rather than dwelt on: forty turns of "nothing
-- happened" at a second each is the list this replaced, only slower. A turn
-- with a battle in it gets longer, because that is the one a player rewinds
-- for.
function M.duration(step, base)
	base = base or 0.9
	if step.quiet then return base * 0.25 end
	if #step.battles > 0 then return base * 1.6 end
	return base
end

return M

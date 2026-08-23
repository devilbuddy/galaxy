--- Turn resolution.
--
-- `resolve.turn(galaxy, state, orders)` advances the game by exactly one turn
-- and returns the events it produced. It is a pure function of its inputs plus
-- the seeded RNG, so a turn can be replayed and a whole game reconstructed from
-- (seed, orders history). That is what makes it testable at LuaJIT speed
-- offline while running on Nakama's much slower interpreter in production.
--
-- Order within a turn:
--   1. production   - population grows, shipyards deliver
--   2. departures   - orders become fleets, ships leave their systems
--   3. movement     - fleets advance along lanes, stopping at hostile systems
--   4. battles      - everything that met this turn fights
--   5. aftermath    - eliminations, then each player's fog of war is updated

local rng = require("galaxy.rng")
local rules = require("galaxy.sim.rules")
local state_mod = require("galaxy.sim.state")
local path_mod = require("galaxy.sim.path")
local view = require("galaxy.sim.view")

local M = {}

local floor, max, min = math.floor, math.max, math.min

local function emit(events, e)
	events[#events + 1] = e
	return e
end

-- 1. Production -------------------------------------------------------------

--- Total ships a player currently has, in systems and in transit.
local function total_ships(state, player)
	local total = 0
	for _, sys in pairs(state.systems) do
		if sys.owner == player then total = total + sys.ships end
	end
	for i = 1, #state.fleets do
		if state.fleets[i].owner == player then total = total + state.fleets[i].ships end
	end
	return total
end

local function production(galaxy, state, events, summaries)
	-- Population first, so this turn's growth counts toward this turn's cap.
	for id = 1, #galaxy.stars do
		local sys = state.systems[id]
		if sys.owner ~= 0 then
			local capacity = state_mod.capacity(galaxy, id)
			-- Growth on remaining headroom, so an empty colony fills quickly and
			-- a full one stagnates. This also lets a freshly claimed system with
			-- zero population get started without a special case.
			local headroom = capacity - sys.population
			if headroom > 0 then
				-- At least one per turn: floor(headroom * rate) reaches zero once
				-- headroom drops below 1/rate, which left every system stalled a
				-- few percent short of capacity forever.
				local growth = max(1, floor(headroom * rules.growth_rate))
				sys.population = min(capacity, sys.population + growth)
			end

			local s = summaries[sys.owner]
			if s then
				s.population = s.population + sys.population
				s.systems = s.systems + 1
			end
		end
	end

	-- Each player gets a shipbuilding budget for the turn: whatever their
	-- population can support, minus what they already field.
	local budget = {}
	for i = 1, #state.players do
		local supported = floor((summaries[i] and summaries[i].population or 0) * rules.fleet_cap_per_pop)
		local have = total_ships(state, i)
		budget[i] = max(0, supported - have)

		if have > supported then
			-- Over the cap: shed the excess, spread across their systems.
			local excess = floor((have - supported) * rules.over_cap_attrition)
			local owned = state_mod.owned_by(state, i)
			local remaining = excess
			for k = 1, #owned do
				if remaining <= 0 then break end
				local sys = state.systems[owned[k]]
				local take = min(sys.ships, max(1, floor(excess / #owned)))
				sys.ships = sys.ships - take
				remaining = remaining - take
			end
			if excess > 0 and summaries[i] then summaries[i].scrapped = excess - max(0, remaining) end
		end
	end

	for id = 1, #galaxy.stars do
		local sys = state.systems[id]
		if sys.owner ~= 0 and budget[sys.owner] and budget[sys.owner] > 0 then
			local rate = rules.ships_per_pop
			if sys.home_of == sys.owner then rate = rate * rules.home_production_bonus end
			local built = min(floor(sys.population * rate), budget[sys.owner])
			if built > 0 then
				sys.ships = sys.ships + built
				budget[sys.owner] = budget[sys.owner] - built
				local s = summaries[sys.owner]
				if s then s.built = s.built + built end
			end
		end
	end
end

-- 2. Departures --------------------------------------------------------------

--- Turn this turn's orders into fleets. Invalid orders are dropped with a
--- reason rather than silently ignored, so a client can show why.
local function departures(galaxy, state, orders, lengths, events)
	for i = 1, #orders do
		local order = orders[i]
		local player = order.player
		local from, to = order.from, order.to
		local sys = state.systems[from]

		local reason = nil
		if not sys then
			reason = "no such system"
		elseif sys.owner ~= player then
			reason = "you do not own the origin"
		elseif not state.systems[to] then
			reason = "no such destination"
		elseif from == to then
			reason = "origin and destination are the same"
		end

		local ships = order.ships and floor(order.ships) or 0
		if not reason then
			-- Clamp rather than reject: the player ordered against the state they
			-- last saw, which may have been a turn out of date.
			ships = min(ships, sys.ships)
			if ships < 1 then reason = "no ships available" end
		end

		local route = nil
		if not reason then
			route = path_mod.find(galaxy, lengths, from, to, rules.max_path_hops)
			if not route or #route == 0 then reason = "no route" end
		end

		if reason then
			emit(events, {
				kind = "order_rejected", turn = state.turn,
				player = player, from = from, to = to, reason = reason,
				visible_to = { player },
			})
		else
			sys.ships = sys.ships - ships
			local fleet = {
				id = state.next_fleet_id,
				owner = player,
				ships = ships,
				at = from,
				path = route,
				destination = to,
				progress = 0,
			}
			state.next_fleet_id = state.next_fleet_id + 1
			state.fleets[#state.fleets + 1] = fleet
		end
	end
end

-- 3. Movement ----------------------------------------------------------------

--- Advance every fleet, and record who ends the turn where.
--
-- A fleet stops the moment it reaches a system held by someone else: lanes can
-- be blockaded, and you cannot slip a fleet past a defended border.
local function movement(galaxy, state, lengths, arrivals)
	local surviving = {}

	for i = 1, #state.fleets do
		local fleet = state.fleets[i]
		local budget = rules.fleet_speed
		local blocked = false

		while budget > 0 and #fleet.path > 0 and not blocked do
			local next_id = fleet.path[1]
			local leg = path_mod.lane_length(lengths, fleet.at, next_id) or 0
			local remaining = leg - fleet.progress

			if budget >= remaining then
				budget = budget - remaining
				fleet.at = next_id
				fleet.progress = 0
				table.remove(fleet.path, 1)

				local sys = state.systems[next_id]
				local hostile = sys.owner ~= 0 and sys.owner ~= fleet.owner
				if hostile or #fleet.path == 0 then
					blocked = true
				end
			else
				fleet.progress = fleet.progress + budget
				budget = 0
			end
		end

		if #fleet.path == 0 or blocked then
			-- The fleet is sitting at a system this turn; group it with anyone
			-- else who turned up, so a system resolves once.
			local at = arrivals[fleet.at]
			if not at then
				at = { order = {}, by_player = {} }
				arrivals[fleet.at] = at
			end
			if not at.by_player[fleet.owner] then
				at.by_player[fleet.owner] = 0
				at.order[#at.order + 1] = fleet.owner
			end
			at.by_player[fleet.owner] = at.by_player[fleet.owner] + fleet.ships
		else
			surviving[#surviving + 1] = fleet
		end
	end

	state.fleets = surviving
end

-- 4. Battles -----------------------------------------------------------------

--- One engagement. Returns the winner's surviving ships.
--
-- A Lanchester-style exchange: the loser is destroyed and the winner keeps the
-- fraction of its force that the margin of victory implies, so a narrow win is
-- expensive and an overwhelming one is nearly free.
local function engage(r, attack, defence)
    local variance = rules.combat_variance
    local a = attack * r:range(1 - variance, 1 + variance)
    local d = defence * r:range(1 - variance, 1 + variance)
    if d <= 0 then return true, attack end
    if a <= 0 then return false, floor(defence / rules.defence_bonus) end
    if a > d then
        return true, max(1, floor(attack * (1 - d / a)))
    end
    return false, max(1, floor((defence / rules.defence_bonus) * (1 - a / d)))
end

local function battles(galaxy, state, arrivals, r, events, summaries)
	-- Sorted so resolution order never depends on table iteration order.
	local ids = {}
	for id in pairs(arrivals) do ids[#ids + 1] = id end
	table.sort(ids)

	for k = 1, #ids do
		local id = ids[k]
		local incoming = arrivals[id]
		local sys = state.systems[id]
		table.sort(incoming.order)

		for oi = 1, #incoming.order do
			local player = incoming.order[oi]
			local ships = incoming.by_player[player]

			if sys.owner == player then
				-- Reinforcement.
				sys.ships = sys.ships + ships
				emit(events, {
					kind = "reinforced", turn = state.turn,
					at = id, player = player, ships = ships,
				})
			elseif sys.owner == 0 then
				-- Unclaimed: taking it is free, and it starts growing next turn.
				sys.owner = player
				sys.ships = ships
				emit(events, {
					kind = "claimed", turn = state.turn,
					at = id, player = player, ships = ships,
				})
			else
				local defender = sys.owner
				local defender_ships = sys.ships
				local won, survivors = engage(r, ships, defender_ships * rules.defence_bonus)

				emit(events, {
					kind = "battle", turn = state.turn, at = id,
					attacker = player, defender = defender,
					attacker_ships = ships, defender_ships = defender_ships,
					winner = won and player or defender,
					survivors = survivors,
					captured = won,
				})

				if won then
					sys.owner = player
					sys.ships = survivors
					sys.population = floor(sys.population * (1 - rules.capture_population_loss))
					-- A captured home system stops being anyone's home.
					if sys.home_of ~= 0 and sys.home_of ~= player then sys.home_of = 0 end
					local s = summaries[player]
					if s then s.captured = s.captured + 1 end
					local d = summaries[defender]
					if d then d.lost = d.lost + 1 end
				else
					sys.ships = survivors
				end
			end
		end
	end
end

-- 5. Aftermath ---------------------------------------------------------------

local function aftermath(galaxy, state, events, summaries)
	for i = 1, #state.players do
		local player = state.players[i]
		if player.alive and not state_mod.is_alive(state, i) then
			player.alive = false
			emit(events, { kind = "eliminated", turn = state.turn, player = i })
		end
	end

	for i = 1, #state.players do
		view.remember(galaxy, state, i)
	end

	-- A private end-of-turn digest per player: the backbone of "what happened
	-- while you were away".
	for i = 1, #state.players do
		local s = summaries[i]
		if s then
			local ships = 0
			for _, sys in pairs(state.systems) do
				if sys.owner == i then ships = ships + sys.ships end
			end
			for f = 1, #state.fleets do
				if state.fleets[f].owner == i then ships = ships + state.fleets[f].ships end
			end
			s.kind = "turn_summary"
			s.turn = state.turn
			s.player = i
			s.ships = ships
			s.visible_to = { i }
			emit(events, s)
		end
	end
end

--- Decide who may see each event.
--
-- Participants always do. Everyone else only if the system it happened at is
-- visible to them at the end of the turn - so a battle on the far side of the
-- map is not broadcast.
local function apply_visibility(galaxy, state, events)
	local visible = {}
	for i = 1, #state.players do
		visible[i] = view.visible_systems(galaxy, state, i)
	end

	for e = 1, #events do
		local event = events[e]
		if not event.visible_to then
			local who = {}
			for i = 1, #state.players do
				local participant = (event.player == i) or (event.attacker == i) or (event.defender == i)
				if participant or (event.at and visible[i][event.at]) then
					who[#who + 1] = i
				end
			end
			-- An elimination is public; it changes the shape of the whole game.
			if event.kind == "eliminated" then
				who = {}
				for i = 1, #state.players do who[#who + 1] = i end
			end
			event.visible_to = who
		end
	end
end

--- Advance the game by one turn.
-- @return events produced this turn
function M.turn(galaxy, state, orders, lengths)
	lengths = lengths or path_mod.lane_lengths(galaxy)
	orders = orders or {}

	state.turn = state.turn + 1
	-- Seeded per turn, so replaying a turn gives identical battles.
	local r = rng.stream(state.seed, "turn:" .. state.turn)

	local events = {}
	local summaries = {}
	for i = 1, #state.players do
		summaries[i] = { built = 0, scrapped = 0, captured = 0, lost = 0, systems = 0, population = 0 }
	end

	production(galaxy, state, events, summaries)
	departures(galaxy, state, orders, lengths, events)

	local arrivals = {}
	movement(galaxy, state, lengths, arrivals)
	battles(galaxy, state, arrivals, r, events, summaries)
	aftermath(galaxy, state, events, summaries)
	apply_visibility(galaxy, state, events)

	return events
end

return M

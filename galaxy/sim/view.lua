--- Fog of war: what each player is allowed to know.
--
-- The star map itself is public - geometry, names and lanes are sent to
-- everyone, because the map is the game's visual centrepiece and hiding it
-- would leave a new player staring at emptiness. What is hidden is the *state*:
-- who owns what, who has ships where, and how strong they are.

local M = {}

--- Systems a player can currently observe.
--
-- Owned systems, everything one lane away from them, and wherever the player
-- has a fleet. One lane of vision means a border system is genuinely a lookout
-- post, and losing it blinds you.
function M.visible_systems(galaxy, state, player)
	local visible = {}

	for id, sys in pairs(state.systems) do
		if sys.owner == player then
			visible[id] = true
			local neighbours = galaxy.adjacency[id]
			for i = 1, #neighbours do
				visible[neighbours[i]] = true
			end
		end
	end

	for i = 1, #state.fleets do
		local fleet = state.fleets[i]
		if fleet.owner == player then
			visible[fleet.at] = true
			if fleet.path[1] then visible[fleet.path[1]] = true end
		end
	end

	return visible
end

--- Fold what a player can see right now into their persistent memory.
--
-- Without this the map would flicker: a system seen last turn would revert to
-- unknown the moment a scout moved on. Remembered entries are stamped with the
-- turn so the client can show them as stale.
function M.remember(galaxy, state, player)
	local visible = M.visible_systems(galaxy, state, player)
	local memory = state.knowledge[player]
	if not memory then
		memory = {}
		state.knowledge[player] = memory
	end
	for id in pairs(visible) do
		local sys = state.systems[id]
		memory[id] = {
			turn = state.turn,
			owner = sys.owner,
			ships = sys.ships,
			population = sys.population,
		}
	end
	return visible
end

--- The state as one player is allowed to receive it.
--
-- Currently visible systems report live values; remembered ones report what was
-- last seen, flagged with the turn. Everything else is omitted entirely rather
-- than sent as zeroes, so the payload cannot leak strength by its shape.
function M.project(galaxy, state, player)
	local visible = M.visible_systems(galaxy, state, player)
	local memory = state.knowledge[player] or {}

	local systems = {}
	for id in pairs(visible) do
		local sys = state.systems[id]
		systems[id] = {
			owner = sys.owner,
			population = sys.population,
			ships = sys.ships,
			home_of = sys.home_of,
			seen = state.turn,
			live = true,
		}
	end
	for id, seen in pairs(memory) do
		if not systems[id] then
			systems[id] = {
				owner = seen.owner,
				population = seen.population,
				ships = seen.ships,
				seen = seen.turn,
				live = false,
			}
		end
	end

	-- Only the player's own fleets. Enemy fleets in transit are invisible;
	-- you learn about them when they arrive.
	local fleets = {}
	for i = 1, #state.fleets do
		local f = state.fleets[i]
		if f.owner == player then
			fleets[#fleets + 1] = {
				id = f.id, ships = f.ships, at = f.at,
				destination = f.destination,
				next_hop = f.path[1],
				eta = #f.path,
			}
		end
	end

	local roster = {}
	for i = 1, #state.players do
		-- Names and liveness are public; holdings are not.
		roster[i] = { name = state.players[i].name, alive = state.players[i].alive }
	end

	return {
		turn = state.turn,
		you = player,
		players = roster,
		systems = systems,
		fleets = fleets,
	}
end

return M

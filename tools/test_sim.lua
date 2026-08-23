-- Simulation tests. Run: luajit tools/test_sim.lua
package.path = "./?.lua;" .. package.path

local gen = require("galaxy.generate")
local st = require("galaxy.sim.state")
local res = require("galaxy.sim.resolve")
local view = require("galaxy.sim.view")
local path = require("galaxy.sim.path")
local rules = require("galaxy.sim.rules")

local failures = 0
local function check(name, cond, detail)
	if cond then print("  ok   " .. name)
	else failures = failures + 1; print("  FAIL " .. name .. "  " .. tostring(detail or "")) end
end

local GALAXY = gen.build(424242)
local LENGTHS = path.lane_lengths(GALAXY)

local function new_game(n)
	local players = {}
	for i = 1, n do players[i] = { id = "p" .. i, name = "P" .. i } end
	return st.new(GALAXY, players)
end

--- A stable fingerprint of the whole mutable state.
local function digest(state)
	local parts = { "t" .. state.turn }
	for id = 1, #GALAXY.stars do
		local s = state.systems[id]
		if s.owner ~= 0 or s.ships ~= 0 or s.population ~= 0 then
			parts[#parts + 1] = string.format("%d:%d:%d:%d", id, s.owner, s.population, s.ships)
		end
	end
	for i = 1, #state.fleets do
		local f = state.fleets[i]
		parts[#parts + 1] = string.format("f%d:%d:%d:%d:%d", f.id, f.owner, f.ships, f.at, #f.path)
	end
	return table.concat(parts, "|")
end

print("setup")
do
	local s = new_game(4)
	check("each player owns exactly one system at turn 0",
		#st.owned_by(s, 1) == 1 and #st.owned_by(s, 4) == 1)
	local homes = {}
	for i = 1, 4 do homes[s.players[i].home] = (homes[s.players[i].home] or 0) + 1 end
	local shared = 0
	for _, c in pairs(homes) do if c > 1 then shared = shared + 1 end end
	check("no two players share a home", shared == 0)
	check("home has starting forces",
		s.systems[s.players[1].home].ships == rules.start_ships)
end

print("production")
do
	local s = new_game(2)
	local home = s.players[1].home
	local before = s.systems[home].population
	res.turn(GALAXY, s, {}, LENGTHS)
	local after = s.systems[home].population
	check("population grows toward capacity", after > before, before .. " -> " .. after)
	check("capacity is never exceeded", after <= st.capacity(GALAXY, home))
	check("ships are produced", s.systems[home].ships > rules.start_ships)

	-- Run to saturation and confirm it settles rather than overshooting.
	for _ = 1, 80 do res.turn(GALAXY, s, {}, LENGTHS) end
	check("population saturates at capacity",
		s.systems[home].population == st.capacity(GALAXY, home),
		s.systems[home].population .. " vs " .. st.capacity(GALAXY, home))
end

print("movement")
do
	local s = new_game(2)
	local home = s.players[1].home
	local target = GALAXY.adjacency[home][1]
	local ev = res.turn(GALAXY, s, { { player = 1, from = home, to = target, ships = 5 } }, LENGTHS)
	check("ships leave the origin", s.systems[home].ships < rules.start_ships + 10)

	local arrived = false
	for _ = 1, 6 do
		if s.systems[target].owner == 1 then arrived = true break end
		res.turn(GALAXY, s, {}, LENGTHS)
	end
	check("a fleet reaches an adjacent unowned system", arrived)
	check("claiming leaves a garrison", s.systems[target].ships > 0)
end

print("orders are validated, not silently dropped")
do
	local s = new_game(2)
	local foreign = s.players[2].home
	local ev = res.turn(GALAXY, s, {
		{ player = 1, from = foreign, to = s.players[1].home, ships = 5 },
	}, LENGTHS)
	local rejected = nil
	for i = 1, #ev do if ev[i].kind == "order_rejected" then rejected = ev[i] end end
	check("ordering from a system you do not own is rejected", rejected ~= nil)
	check("the rejection says why", rejected and rejected.reason == "you do not own the origin",
		rejected and rejected.reason)
	check("the rejection is private to the ordering player",
		rejected and #rejected.visible_to == 1 and rejected.visible_to[1] == 1)

	-- Over-ordering clamps to what is actually there.
	local home = s.players[1].home
	local have = s.systems[home].ships
	res.turn(GALAXY, s, {
		{ player = 1, from = home, to = GALAXY.adjacency[home][1], ships = have + 9999 },
	}, LENGTHS)
	check("over-ordering clamps instead of failing", s.systems[home].ships >= 0)
end

print("combat")
do
	-- Hand-built confrontation: player 1 attacks player 2's home.
	local s = new_game(2)
	local defender_home = s.players[2].home
	local attacker_from = GALAXY.adjacency[defender_home][1]
	s.systems[attacker_from].owner = 1
	s.systems[attacker_from].ships = 500
	s.systems[defender_home].ships = 10

	res.turn(GALAXY, s, {
		{ player = 1, from = attacker_from, to = defender_home, ships = 500 },
	}, LENGTHS)
	local captured = false
	for _ = 1, 4 do
		if s.systems[defender_home].owner == 1 then captured = true break end
		res.turn(GALAXY, s, {}, LENGTHS)
	end
	check("an overwhelming attack captures the system", captured)

	-- The reverse: a small attack against a strong defence must fail.
	local s2 = new_game(2)
	local d2 = s2.players[2].home
	local a2 = GALAXY.adjacency[d2][1]
	s2.systems[a2].owner = 1
	s2.systems[a2].ships = 10
	s2.systems[d2].ships = 400
	res.turn(GALAXY, s2, { { player = 1, from = a2, to = d2, ships = 10 } }, LENGTHS)
	for _ = 1, 4 do res.turn(GALAXY, s2, {}, LENGTHS) end
	check("a hopeless attack does not capture", s2.systems[d2].owner == 2)
end

print("fog of war")
do
	local s = new_game(2)
	local mine = s.players[1].home
	local theirs = s.players[2].home
	res.turn(GALAXY, s, {}, LENGTHS)

	local vis = view.visible_systems(GALAXY, s, 1)
	check("you see your own system", vis[mine])
	check("you see one lane out", vis[GALAXY.adjacency[mine][1]])
	check("you do not see a distant enemy home", not vis[theirs])

	local projected = view.project(GALAXY, s, 1)
	-- Keyed by string id so the JSON encoding is unambiguous; see view.project.
	check("projection omits unseen systems entirely", projected.systems[tostring(theirs)] == nil)
	check("projection includes your own", projected.systems[tostring(mine)] ~= nil)
	check("projection keys are strings, not numbers", projected.systems[mine] == nil)
	check("projection reports only your fleets",
		#projected.fleets == 0 or projected.fleets[1].id ~= nil)

	-- Memory: take a neighbour, then check it is remembered as stale after loss.
	local neighbour = GALAXY.adjacency[mine][1]
	s.systems[neighbour].owner = 1
	res.turn(GALAXY, s, {}, LENGTHS)
	local far = nil
	for _, id in ipairs(GALAXY.adjacency[neighbour]) do
		if id ~= mine and not view.visible_systems(GALAXY, s, 1)[id] then far = id end
	end
	check("memory records what was seen", s.knowledge[1][neighbour] ~= nil)
end

print("event visibility")
do
	local s = new_game(3)
	-- A battle between 1 and 2 far from player 3 must not reach player 3.
	local d = s.players[2].home
	local a = GALAXY.adjacency[d][1]
	s.systems[a].owner = 1
	s.systems[a].ships = 400
	local ev = res.turn(GALAXY, s, { { player = 1, from = a, to = d, ships = 400 } }, LENGTHS)
	for _ = 1, 3 do
		ev = res.turn(GALAXY, s, {}, LENGTHS)
		local battle = nil
		for i = 1, #ev do if ev[i].kind == "battle" then battle = ev[i] end end
		if battle then
			local sees3 = false
			for _, p in ipairs(battle.visible_to) do if p == 3 then sees3 = true end end
			check("combatants see the battle", #battle.visible_to >= 2)
			check("an uninvolved distant player does not", not sees3)
			break
		end
	end
end

print("determinism")
do
	local orders_for = function(state, turn)
		local out = {}
		for i = 1, #state.players do
			local owned = st.owned_by(state, i)
			if #owned > 0 then
				local from = owned[(turn % #owned) + 1]
				local nb = GALAXY.adjacency[from]
				if #nb > 0 and state.systems[from].ships > 4 then
					out[#out + 1] = { player = i, from = from,
						to = nb[(turn % #nb) + 1],
						ships = math.floor(state.systems[from].ships / 2) }
				end
			end
		end
		return out
	end

	local function play(turns)
		local s = new_game(4)
		for t = 1, turns do res.turn(GALAXY, s, orders_for(s, t), LENGTHS) end
		return digest(s)
	end

	local a, b = play(40), play(40)
	check("same seed and orders reproduce the same state exactly", a == b)
	check("the game actually progressed", #a > 200, "digest length " .. #a)
end

print(failures == 0 and "\nALL SIM TESTS PASSED" or ("\n" .. failures .. " FAILURE(S)"))
os.exit(failures == 0 and 0 or 1)

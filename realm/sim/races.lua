--- Playable peoples, expressed purely as modifiers.
--
-- A race is a bundle of the same effect keys the tech tree uses (see
-- realm/sim/tech.lua), so nothing in the resolver has to know a race exists:
-- `modifiers.of(state, player)` folds race and researched tech into one table
-- and the rules read that. Adding a race is a data change, not a code change.
--
-- **The ids are frozen; only the fiction on top of them moved.** These were
-- Terran / Vorn / Ashai / Kepler / Cartel / Silicate, a fleet of star nations
-- left over from before the map became a realm. Renaming the *ids* would have
-- stranded every stored game and every seat a bot has claimed, so what changed
-- is `label` and `blurb` - and, in main/theme.lua, the art each one wears. Read
-- an id as a slot, not as a name.
--
-- What a people looks like is deliberately not here: `main/theme.lua` holds the
-- faces, the unit glyphs and what this people calls its units and buildings.
-- This file is loaded by gopher-lua on Nakama, which never draws anything.
--
-- Balance intent: every race is strong at one of the three things the economy
-- can buy - mass, mobility or knowledge - and pays for it somewhere the player
-- will actually feel. A pure-upside race would just be the correct pick.

local M = {}

-- `mods` values are additive fractions applied on top of 1.0, so 0.25 means
-- +25% and -0.20 means -20%. The integer keys (vision, hops) are added whole.
M.RACES = {
	{
		id = "terran",
		label = "Freeholders",
		blurb = "Farm folk who fight because the harvest is behind them.",
		colour = { 0.45, 0.72, 1.00 },
		mods = { growth = 0.10, research = 0.10, capture = 0.10 },
	},
	{
		id = "vorn",
		label = "Iron Order",
		blurb = "Conquest first. Everything else is logistics.",
		colour = { 0.95, 0.34, 0.30 },
		mods = { attack = 0.25, industry = 0.15, research = -0.25, growth = -0.20 },
	},
	{
		id = "ashai",
		label = "The Barrow",
		blurb = "Outlasts every rival, mostly by already being dead.",
		colour = { 0.52, 0.88, 0.48 },
		mods = { growth = 0.40, capacity = 0.20, attack = -0.20, industry = -0.15 },
	},
	{
		id = "kepler",
		label = "The Circle",
		blurb = "Wins the last war, not the first.",
		colour = { 0.72, 0.60, 1.00 },
		mods = { research = 0.35, tech_cost = -0.20, industry = -0.25, defence = -0.10 },
	},
	{
		id = "cartel",
		label = "Free Company",
		blurb = "Arrives before you knew they had left.",
		colour = { 1.00, 0.78, 0.30 },
		mods = { speed = 0.25, hops = 3, ship_cost = -0.15, defence = -0.15 },
	},
	{
		id = "silicate",
		label = "Stonekin",
		blurb = "Takes ground slowly and never gives it back.",
		colour = { 0.60, 0.86, 0.90 },
		mods = { defence = 0.25, fortress = 0.40, building_cost = -0.25,
			growth = -0.35, research = -0.15 },
	},
}

M.DEFAULT = "terran"

local BY_ID = {}
for i = 1, #M.RACES do BY_ID[M.RACES[i].id] = M.RACES[i] end

--- Look a race up by id, falling back to the default rather than returning nil.
--
-- Every caller would otherwise need the same guard: a state written before a
-- race existed, or a client sending a typo, must not crash turn resolution.
function M.by_id(id)
	return BY_ID[id] or BY_ID[M.DEFAULT]
end

--- Is this a race id the server recognises?
function M.exists(id)
	return BY_ID[id] ~= nil
end

--- Ids in declaration order, for a client that wants to list them.
function M.ids()
	local out = {}
	for i = 1, #M.RACES do out[i] = M.RACES[i].id end
	return out
end

return M

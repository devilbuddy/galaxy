--- Playable races, expressed purely as modifiers.
--
-- A race is a bundle of the same effect keys the tech tree uses (see
-- galaxy/sim/tech.lua), so nothing in the resolver has to know a race exists:
-- `modifiers.of(state, player)` folds race and researched tech into one table
-- and the rules read that. Adding a race is a data change, not a code change.
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
		label = "Terran Concord",
		blurb = "Adaptable, unremarkable, hard to corner.",
		colour = { 0.45, 0.72, 1.00 },
		mods = { growth = 0.10, yield_research = 0.10, capture = 0.10 },
	},
	{
		id = "vorn",
		label = "Vorn Hegemony",
		blurb = "Conquest first. Everything else is logistics.",
		colour = { 0.95, 0.34, 0.30 },
		mods = { attack = 0.25, industry = 0.15, yield_research = -0.25, growth = -0.20 },
	},
	{
		id = "ashai",
		label = "Ashai Collective",
		blurb = "Outbreeds every rival, then outlasts them.",
		colour = { 0.52, 0.88, 0.48 },
		mods = { growth = 0.40, capacity = 0.20, attack = -0.20, yield_metal = -0.15 },
	},
	{
		id = "kepler",
		label = "Kepler Institute",
		blurb = "Wins the last war, not the first.",
		colour = { 0.72, 0.60, 1.00 },
		mods = { yield_research = 0.35, tech_cost = -0.20, industry = -0.25, defence = -0.10 },
	},
	{
		id = "cartel",
		label = "Drift Cartels",
		blurb = "Every lane is a ledger entry.",
		colour = { 1.00, 0.78, 0.30 },
		mods = { trade = 0.50, speed = 0.20, yield_fuel = 0.30, defence = -0.15, industry = -0.10 },
	},
	{
		id = "silicate",
		label = "Silicate Chorus",
		blurb = "Machines do not need feeding, only feeding stock.",
		colour = { 0.60, 0.86, 0.90 },
		mods = { yield_metal = 0.30, upkeep = -0.40, defence = 0.20, growth = -0.35, yield_research = -0.15 },
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

--- The three things a colony can put aboard a captain.
--
-- Composition is the second decision the game has ever had. The first is where
-- to go; this is what to bring. It exists because **resistance already has two
-- halves and they are both public**: a world's own fortification, which is
-- derived from the star and whatever has been built on it, and whatever fleet
-- is standing on it. A type that is good against one is poor against the other,
-- so an army is aimed rather than merely large.
--
--   Line    the front rank. Equal against both, and what dies first.
--   Lance   ships. Three times itself against a fleet, ordinary against walls.
--   Siege   guns. Three times itself against walls, ordinary against a fleet.
--
-- **The weights are small integers on purpose.** A player has to be able to add
-- their army up in their head and compare it against two numbers on the sheet -
-- that is the whole reason combat has never needed a forecast, and it survives
-- unit types only because the arithmetic stayed this size.
--
-- Ordered, never keyed by `pairs`: two runtimes have to agree on what a turn
-- contained, and the order below is the order everything iterates in.

local M = {}

-- The two halves of any resistance, and the two questions an army is asked.
M.FORTIFICATION = "fortification"
M.FLEET = "fleet"

M.CATALOGUE = {
	{
		id = "line",
		name = "Line",
		blurb = "The front rank. Dies first, so the rest do not.",
		cost = 20,
		fortification = 1,
		fleet = 1,
	},
	{
		id = "lance",
		name = "Lance",
		blurb = "Three times itself against ships.",
		cost = 34,
		fortification = 1,
		fleet = 3,
	},
	{
		id = "siege",
		name = "Siege",
		blurb = "Three times itself against walls.",
		cost = 34,
		fortification = 3,
		fleet = 1,
	},
}

local BY_ID = {}
for i = 1, #M.CATALOGUE do BY_ID[M.CATALOGUE[i].id] = M.CATALOGUE[i] end

function M.by_id(id)
	return BY_ID[id]
end

function M.exists(id)
	return BY_ID[id] ~= nil
end

--- Ids in catalogue order.
function M.ids()
	local out = {}
	for i = 1, #M.CATALOGUE do out[i] = M.CATALOGUE[i].id end
	return out
end

-- A hold ------------------------------------------------------------------------

--- An empty complement, with every type present as a zero.
--
-- Dense on purpose: a table of three named zeroes survives a JSON round trip
-- as an object, where a sparse one can come back with no keys at all.
function M.empty()
	local out = {}
	for i = 1, #M.CATALOGUE do out[M.CATALOGUE[i].id] = 0 end
	return out
end

--- Repair a complement read back from storage.
function M.normalise(hold)
	local out = M.empty()
	if type(hold) ~= "table" then return out end
	for i = 1, #M.CATALOGUE do
		local id = M.CATALOGUE[i].id
		local n = tonumber(hold[id]) or 0
		if n < 0 then n = 0 end
		out[id] = math.floor(n)
	end
	return out
end

--- How many units are aboard, of every type.
function M.count(hold)
	local n = 0
	for i = 1, #M.CATALOGUE do n = n + ((hold and hold[M.CATALOGUE[i].id]) or 0) end
	return n
end

--- What a complement is worth against one half of a resistance.
--
-- `against` is M.FORTIFICATION or M.FLEET. Anything else reads as fleet, which
-- is the safer default: a captain caught in the open is the case where being
-- wrong matters most.
function M.power(hold, against)
	local key = (against == M.FORTIFICATION) and "fortification" or "fleet"
	local total = 0
	for i = 1, #M.CATALOGUE do
		local spec = M.CATALOGUE[i]
		total = total + ((hold and hold[spec.id]) or 0) * spec[key]
	end
	return total
end

--- What a complement cost to put together, at catalogue prices.
function M.price(hold)
	local total = 0
	for i = 1, #M.CATALOGUE do
		local spec = M.CATALOGUE[i]
		total = total + ((hold and hold[spec.id]) or 0) * spec.cost
	end
	return total
end

--- Take `n` units off a complement, cheapest rank first.
--
-- **Line dies first**, which is what makes it worth buying: it is the only type
-- whose job is to still be there when the shooting stops. Then Lance, then
-- Siege - a battery is the last thing a fleet gives up.
--
-- Returns what was actually removed, which is fewer than asked for when the
-- hold runs out.
function M.strip(hold, n)
	local removed = M.empty()
	for i = 1, #M.CATALOGUE do
		if n <= 0 then break end
		local id = M.CATALOGUE[i].id
		local take = (hold[id] or 0)
		if take > n then take = n end
		hold[id] = (hold[id] or 0) - take
		removed[id] = take
		n = n - take
	end
	return removed
end

return M

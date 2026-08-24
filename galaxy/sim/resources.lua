--- The three things an empire runs on, and which systems produce them.
--
-- Three is deliberate. One resource is just a score; five means every screen
-- needs a spreadsheet. Three gives each of the game's decisions its own
-- currency and lets a system be genuinely good at one thing and poor at
-- another:
--
--   metal     hulls and hardware. Only comes out of ground you hold, so
--             military mass always has to be paid for in territory.
--   fuel      movement and upkeep. Caps how far from home you can fight
--             rather than how much you can build.
--   research  the tech tree, and nothing else.
--
-- A system's *base* yield is a pure function of its star class and feature -
-- both of which are already public map data - so every player can read the
-- economic value of a system they have never visited, and conquest can be
-- planned. What stays private is the population multiplying it.

local starclass = require("galaxy.starclass")

local M = {}

-- Declaration order is the display order, and the order every summary uses.
M.KINDS = { "metal", "fuel", "research" }

M.LABELS = { metal = "Metal", fuel = "Fuel", research = "Research" }

-- Per star class, relative to an average system of 1.0 across the three.
-- Cold, dim stars are ordinary mining posts; energetic and exotic objects are
-- poor places to live but excellent places to refuel or study.
local CLASS_YIELD = {
	red_dwarf    = { metal = 1.00, fuel = 0.60, research = 0.60 },
	orange_dwarf = { metal = 1.00, fuel = 0.80, research = 0.80 },
	yellow       = { metal = 0.90, fuel = 0.90, research = 1.10 },
	amber_giant  = { metal = 1.30, fuel = 1.10, research = 0.70 },
	white        = { metal = 0.90, fuel = 1.10, research = 1.20 },
	blue_giant   = { metal = 0.80, fuel = 1.60, research = 1.00 },
	red_giant    = { metal = 1.50, fuel = 1.20, research = 0.60 },
	pulsar       = { metal = 0.50, fuel = 1.90, research = 1.50 },
	black_hole   = { metal = 0.40, fuel = 1.70, research = 2.00 },
	nebula       = { metal = 0.60, fuel = 1.80, research = 1.30 },
}

-- Features add on top, flat. These are what turn an otherwise dull red dwarf
-- into somewhere worth a war.
local FEATURE_YIELD = {
	asteroids = { metal = 0.90, fuel = 0.00, research = 0.10 },
	anomaly   = { metal = 0.00, fuel = 0.20, research = 0.80 },
	derelict  = { metal = 0.50, fuel = 0.00, research = 0.40 },
	relay     = { metal = 0.00, fuel = 0.60, research = 0.00 },
	ruins     = { metal = 0.00, fuel = 0.00, research = 1.10 },
	nebula    = { metal = 0.00, fuel = 0.70, research = 0.20 },
}

-- Habitable worlds have people in them doing something other than mining.
local HABITABLE_YIELD = { metal = 0.10, fuel = 0.00, research = 0.35 }

local ZERO = { metal = 0, fuel = 0, research = 0 }

--- A fresh, zeroed stockpile.
function M.zero()
	return { metal = 0, fuel = 0, research = 0 }
end

--- Base yield of one system, before population and modifiers.
--
-- Results are memoised on the galaxy itself. Turn resolution asks for this
-- once per owned system per turn and the answer never changes for a given
-- seed, so recomputing it is pure waste - and on gopher-lua, which walks the
-- AST, it is waste that shows up in the RPC latency.
function M.base_yield(galaxy, star_id)
	local cache = galaxy.yield_cache
	if not cache then
		cache = {}
		galaxy.yield_cache = cache
	end
	local hit = cache[star_id]
	if hit then return hit end

	local star = galaxy.stars[star_id]
	if not star then return ZERO end

	local from_class = CLASS_YIELD[star.class] or CLASS_YIELD.yellow
	local out = {
		metal = from_class.metal,
		fuel = from_class.fuel,
		research = from_class.research,
	}

	local from_feature = FEATURE_YIELD[star.feature]
	if from_feature then
		out.metal = out.metal + from_feature.metal
		out.fuel = out.fuel + from_feature.fuel
		out.research = out.research + from_feature.research
	end

	if star.habitable then
		out.metal = out.metal + HABITABLE_YIELD.metal
		out.fuel = out.fuel + HABITABLE_YIELD.fuel
		out.research = out.research + HABITABLE_YIELD.research
	end

	cache[star_id] = out
	return out
end

--- Which resource a system is best at, for a one-glance map label.
-- Ties break in KINDS order, so the answer never depends on table iteration.
function M.speciality(galaxy, star_id)
	local y = M.base_yield(galaxy, star_id)
	local best, bestv = M.KINDS[1], y[M.KINDS[1]]
	for i = 2, #M.KINDS do
		local kind = M.KINDS[i]
		if y[kind] > bestv then best, bestv = kind, y[kind] end
	end
	return best, bestv
end

--- Add `b` into `a` in place.
function M.add(a, b)
	a.metal = a.metal + (b.metal or 0)
	a.fuel = a.fuel + (b.fuel or 0)
	a.research = a.research + (b.research or 0)
	return a
end

--- Can `stock` pay `cost`?
function M.can_pay(stock, cost)
	return (stock.metal or 0) >= (cost.metal or 0)
		and (stock.fuel or 0) >= (cost.fuel or 0)
		and (stock.research or 0) >= (cost.research or 0)
end

--- Deduct `cost` from `stock` in place. Callers check `can_pay` first.
function M.pay(stock, cost)
	stock.metal = (stock.metal or 0) - (cost.metal or 0)
	stock.fuel = (stock.fuel or 0) - (cost.fuel or 0)
	stock.research = (stock.research or 0) - (cost.research or 0)
	return stock
end

--- Repair a stockpile that has been through JSON, or was never written.
--
-- Nakama stores state as JSON and a table of three zeroes is indistinguishable
-- from an empty object once it comes back, so every field is re-defaulted
-- rather than trusted.
function M.normalise(stock)
	if type(stock) ~= "table" then return M.zero() end
	return {
		metal = tonumber(stock.metal) or 0,
		fuel = tonumber(stock.fuel) or 0,
		research = tonumber(stock.research) or 0,
	}
end

return M

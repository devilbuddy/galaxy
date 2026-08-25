--- Tunable rules for the simulation.
--
-- Everything the game's balance depends on lives here so it can be adjusted
-- without reading the resolution logic. Values are per *turn*, and a turn is a
-- scheduled batch, not a real-time tick.
--
-- The game is being rebuilt from its foundations. Right now it is this: every
-- player has a capital and one captain, captains move along lanes, whatever
-- they pass through becomes theirs, and a captain with enough **strength**
-- takes ground somebody else holds. There is still no production and no
-- research; their constants will arrive with the code that reads them rather
-- than sitting here describing a game that is not running.

return {
	-- Movement ----------------------------------------------------------------
	-- Lanes a captain crosses per turn.
	--
	-- **Discrete on purpose.** Movement used to be a distance - 95 world units
	-- a turn along lanes varying from roughly 60 to 200 - which meant "when
	-- does Kess arrive?" had no answer a player could work out. Lane length is
	-- not drawn, not stated and cannot be eyeballed, so the number the rule
	-- depended on was invisible. A step is countable off the map: a four-lane
	-- route takes four turns.
	--
	-- What this gives up is that lane *length* no longer means anything. If it
	-- is missed, the way back is to price some lanes at two steps and draw them
	-- as such - not to return to a continuous speed nobody can see.
	captain_steps = 1,
	-- Rank buys reach rather than pace, so progression is legible: a Commodore
	-- moves two systems a turn, a Grand Admiral three.
	steps_at_rank = { [5] = 1, [9] = 1 },
	-- A race with a mobility bonus gets a whole extra step. Fractions of a step
	-- would be exactly the invisible arithmetic this replaced.
	step_race_threshold = 0.2,
	-- How far ahead a route may be plotted, in lanes. Standing orders are what
	-- make a game checked twice a day playable rather than tedious.
	max_route_hops = 12,          -- baseline (via hops)

	-- Strength -----------------------------------------------------------------
	-- What a captain can spend to take ground, and the ceiling it recovers to.
	--
	-- **The whole model is one comparison, and every number in it is on screen.**
	-- A captain attacks only when it can win; otherwise it stops at the border
	-- exactly as it did before combat existed. So there are no failed assaults,
	-- no dice, and nothing to misjudge - which is the only way an attack can be
	-- a decision rather than a gamble in a game checked twice a day.
	captain_strength = 12,
	strength_per_level = 3,

	-- What it costs to take a system, by what kind of place it is. Public map
	-- data (galaxy/sim/systems.lua derives kind from the star), so a player can
	-- price a conquest from the other side of the galaxy.
	--
	-- A waypoint is terrain and barely resists; a colony costs most of a fresh
	-- captain. With recovery at `strength_recovery` a turn, a chain of waypoints
	-- is effectively free to walk and a colony is a real decision - which is the
	-- distinction the map is drawn around.
	defence = { waypoint = 2, outpost = 5, colony = 9 },
	-- On top of the kind. A capital is the losing condition, so taking one
	-- should need a captain who has been winning, not a fresh one.
	capital_defence = 12,

	-- Regained per turn, but only on ground you hold: an army in somebody
	-- else's space is an army out of supply. It is what stops a deep raid from
	-- continuing indefinitely, and what makes going home mean something.
	strength_recovery = 3,
	capital_recovery = 8,

	commander_max_level = 10,
	-- Experience is the strength a captain has overcome, so a colony is worth
	-- more than a waypoint without anything having to say so. Low enough that a
	-- promotion is a few real fights rather than a campaign - the ladder was
	-- written when experience meant ships destroyed and there were thousands of
	-- them about.
	commander_xp_base = 8,

	-- Intelligence ------------------------------------------------------------
	-- Lanes of vision from each source. A captain sees barely past itself; a
	-- world you hold sees its own neighbourhood.
	base_vision = 1,              -- baseline (via vision)
	captain_vision = 1,

	-- Regions -----------------------------------------------------------------
	-- The map is far larger than anyone will hold, so the objective is the
	-- region rather than the system count - see galaxy/sim/regions.lua.
	victory_region_fraction = 0.5,

	-- Starting position -------------------------------------------------------
	-- A capital must have somewhere to expand into, or the game is decided at
	-- generation rather than in play.
	capital_hops = 3,
	capital_neighbours = 3,
}

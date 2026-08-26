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
	-- What the officer brings on their own, before anything is bought. It is
	-- never *spent* - a battle takes units, and an officer with none loses
	-- nothing - which is precisely why it has to stay small.
	--
	-- It was 12 and +3 a level, and that made an army optional: a level-four
	-- officer's own command out-fought any colony on the map and could do it
	-- again every turn, for ever, at no cost at all. Six and +1 keeps a bare
	-- captain able to walk into empty space and take a waypoint or an outpost -
	-- which is what early expansion is - while a colony at 9 needs something
	-- aboard and a capital at 21 needs a real army.
	captain_strength = 6,
	strength_per_level = 1,

	-- And how many bought units they can lead on top of that. **Rank must not
	-- cap what a captain can carry**, only what they start with: capping the
	-- total at the rank base walled the game shut, because a fresh captain
	-- could never cover a defended colony and could never win the battle that
	-- would have promoted them. Capacity is generous and grows with rank, so
	-- experience buys reach rather than gating the economy.
	captain_units = 6,
	units_per_level = 1,

	-- What it costs to take a system, by what kind of place it is. Public map
	-- data (galaxy/sim/systems.lua derives kind from the star), so a player can
	-- price a conquest from the other side of the galaxy.
	--
	-- A waypoint is terrain and barely resists; a colony costs most of a fresh
	-- captain. That is the distinction the map is drawn around.
	defence = { waypoint = 2, outpost = 5, colony = 9 },
	-- On top of the kind. A capital is the losing condition, so taking one
	-- should need a captain who has been winning, not a fresh one.
	capital_defence = 12,


	-- Supply and units ---------------------------------------------------------
	-- **One currency, two things it cannot be in at once.** Supply accrues from
	-- everything you hold and is fungible across the map; units accumulate only
	-- at colonies, only up to a cap, and only become strength where a captain is
	-- standing. So wealth alone never wins a front - it converts to force at a
	-- colony, and a captain has to walk there.
	--
	-- Per system per turn, scaled by the star's own `industry` and rounded to a
	-- whole number.
	--
	-- **Road pays nothing.** A waypoint used to pay 1, which meant walking a
	-- captain down an empty chain was income for the rest of the game - and the
	-- map had already decided that was the wrong measure. `regions.lua` counts
	-- only colonies and outposts towards victory, so waypoints were already
	-- terrain for the purpose of *winning* and still wages for the purpose of
	-- *paying*. This closes that.
	--
	-- Colonies are towns and outposts are mines, which is the shape this is
	-- lifted from. **It is a redistribution rather than a cut**: measured over
	-- five seeds, waypoints were 45% of the systems and 22% of the income, and
	-- moving that onto the other two at these rates leaves whole-galaxy income
	-- within a percent of what it was. What changes is not how much an empire
	-- earns but what it is worth going to get - a colony now averages 4.7 a
	-- turn and an outpost 3.2, and the road between them averages nothing.
	supply_yield = { waypoint = 0, outpost = 2.5, colony = 4 },

	-- What a player's capital pays on top of its own yield.
	--
	-- **This is what makes the opening work.** With road paying nothing, a
	-- player who has taken two systems and a stretch of lane earns almost
	-- exactly what they earned on turn one - and the capital is the only thing
	-- anybody is guaranteed to hold. Without it the first stretch of a game is
	-- a player watching a number that does not move.
	--
	-- It is a shape rather than a decision: the capital is placed by the
	-- generator, so there is nothing to choose. The version with a choice in it
	-- is a building that pays, and there is no room for one at four slots.
	capital_yield = 12,

	-- What a colony holds ready, and how often another becomes available.
	-- Availability accumulates whether or not anyone visits and does not decay,
	-- so a distant colony is not wasted production - it is a reason to march.
	-- Measured, not guessed. At a cap of 4 the median four-player game took 283
	-- turns; at 6 it takes 190, which is where pacing sat before there was an
	-- economy at all. Making stock accrue *every* turn instead of every other
	-- is worse than either - every seed tried then ran past 1500 turns without
	-- deciding, because a front where both sides refit as fast as they can
	-- spend never moves.
	colony_stock_cap = 6,
	colony_stock_turns = 2,

	-- Combat ---------------------------------------------------------------------
	-- **Whether you win is computed; what it costs is simulated.**
	--
	-- Two comparisons decide the first, both integer and both on the sheet: your
	-- siege power against the world's fortification, and your fleet power
	-- against whatever fleet is standing on it. Beat both and you take it. That
	-- is the arithmetic a player does before committing a captain to a turn that
	-- resolves twelve hours later, and it is why combat has never needed a
	-- forecast.
	--
	-- The **exchanges** then distribute the cost. An exchange is a trade of
	-- damage *inside* a single turn - the whole battle is over before the turn
	-- that started it finishes, and nobody else acts in between. It is not a
	-- turn, and the two words must not be swapped.
	--
	-- Losses follow Lanchester's linear law: two forces grinding each other down
	-- in proportion leave the winner having lost `D*D/A`, so a well-composed
	-- army both finishes sooner and comes out of it larger. It is also **provably
	-- consistent with the comparison** - `D*D/A < D < A` whenever `A > D` - so a
	-- player who did the arithmetic and was told they would win, wins.
	exchange_depth = 4,       -- how drawn-out an even fight is
	max_exchanges = 6,        -- and the most a replay will ever have to show
	-- What a captain's own rank absorbs each exchange before their units take
	-- anything, as a level divisor. A veteran wins the same fights and comes out
	-- of them stronger, which is worth more than any single battle - and because
	-- it only ever reduces losses, it can never flip a fight the player had
	-- calculated as winnable.
	shield_per_levels = 2,

	-- Stock deliberately does **not** defend the colony holding it. It did, and
	-- it nearly doubled what a colony cost to take - which re-froze the map that
	-- combat had just unfrozen, because defence accumulated for free while an
	-- attacker had to carry theirs across the galaxy. Fortifying is a choice a
	-- player makes, not something that happens to a world nobody visited.
	--
	-- What a unit is *worth* and what it *costs* now both depend on its type -
	-- see galaxy/sim/units.lua. A colony's stock is still counted in units of
	-- any kind, because a berth is a berth.

	-- Orders --------------------------------------------------------------------
	-- **How many decisions a turn is worth.** Not a safety limit - a scarcity.
	-- With an empire of four captains and a dozen colonies there is always more
	-- worth doing than this allows, so a turn is a choice about what matters
	-- most rather than a round of housekeeping.
	--
	-- It works at three because **a route is a standing order**: a captain given
	-- somewhere to go keeps going, across as many turns as it takes, without
	-- costing anything further. An order is what it costs to *change* a plan,
	-- not to maintain one, and most turns have only one or two things worth
	-- changing.
	orders_per_turn = 3,

	-- What each kind costs, as data rather than a rule buried in the resolver,
	-- so making one of them free is a single edit. Resupply is deliberately not
	-- free: a captain that could always top up for nothing would always top up,
	-- and collecting would be a chore rather than a decision again.
	order_cost = { move = 1, build = 1, recruit = 1, resupply = 1 },

	-- Buildings ----------------------------------------------------------------
	-- Two slots against four buildings, so a colony specialises rather than
	-- accumulating everything. See galaxy/sim/buildings.lua for what each does.
	building_slots = 2,
	yards_stock = 4,          -- Yards: units held ready, on top of the base
	bastion_defence = 8,      -- Bastion: flat resistance

	-- Captains. One to begin with, one more per Admiralty, and a hard ceiling
	-- because the commander strip is a row of faces rather than a list.
	captain_cap = 1,
	captain_cap_max = 4,
	captain_cost = 180,

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

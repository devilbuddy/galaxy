-- The staged order plan: what survives a send, and what a resolving turn takes.
--
-- Written for one specific defect. `game.orders` *replaces* the batch the server
-- holds rather than appending to it, and the client used to clear `store.orders`
-- as soon as a send succeeded. So the sequence any player would actually
-- perform - send an order, notice another one, send again - shipped a second
-- batch containing only the new order, and the server dutifully threw the first
-- one away. Nothing errored and the button said SEND both times.
--
-- Run: luajit tools/test_plan.lua

package.path = "./?.lua;" .. package.path

local store = require("main.store")

local failures = 0

local function check(name, ok, detail)
	if ok then
		print("  ok   " .. name)
	else
		failures = failures + 1
		print("  FAIL " .. name .. (detail and ("  (" .. detail .. ")") or ""))
	end
end

local function reset()
	store.orders = {}
	store.orders_turn = nil
	store.sent_signature = nil
	store.sent_turn = nil
end

--- What a send would put on the wire, built the way main/hud.gui_script does.
local function payload()
	local out = {}
	for i = 1, #store.orders do out[#out + 1] = store.orders[i] end
	return out
end

local function unsent()
	if store.plan_count() == 0 then return false end
	return store.sent_signature ~= store.plan_signature()
end

print("plan: counting")
reset()
check("empty plan counts zero", store.plan_count() == 0)
check("empty plan has nothing unsent", not unsent())
store.orders[1] = { kind = "move", commander = 4, route = { 2 } }
check("one order counts one", store.plan_count() == 1)

print("plan: unsent detection")
reset()
store.orders[1] = { kind = "move", commander = 7, route = { 3 } }
check("a fresh order is unsent", unsent())
store.plan_sent(50)
check("sending clears it", not unsent())
store.orders[2] = { kind = "move", commander = 1, route = { 9 } }
check("adding one makes it unsent again", unsent())
store.plan_sent(50)
check("sending again clears it", not unsent())
store.orders[1].route = { 4 }
check("revising an order in place is unsent", unsent())

print("plan: a send does not wipe what it sent")
reset()
store.orders[1] = { kind = "move", commander = 3, route = { 9 } }
local first = payload()
check("first send carries one order", #first == 1, "#=" .. #first)
store.plan_sent(50)
check("the plan survives the send", store.plan_count() == 1,
	"count=" .. store.plan_count())

-- The defect, exactly: notice a second move and send again.
store.orders[2] = { kind = "move", commander = 5, route = { 11 } }
local second = payload()
check("the second send carries BOTH orders", #second == 2, "#=" .. #second)
check("...including the one from the first send",
	second[1].kind == "move" and second[1].commander == 3)
check("...and the second order",
	second[2].kind == "move" and second[2].commander == 5)

print("plan: a resolving turn consumes it")
reset()
store.orders[1] = { kind = "move", commander = 2, route = { 8 } }
store.plan_sent(60)
check("an earlier turn resolving leaves it alone", not store.plan_consumed(59))
check("...and it still holds it", store.plan_count() == 1)
check("its own turn resolving consumes it", store.plan_consumed(60))
check("...leaving nothing staged", store.plan_count() == 0)
check("...and no research", store.pending_research == nil)
check("...and nothing marked sent", store.sent_signature == nil
	and store.sent_turn == nil and store.orders_turn == nil)

-- A player who staged orders but never sent them still has them consumed: the
-- turn they were aimed at has gone, and a launch route is only valid against
-- the map that produced it.
reset()
store.orders[1] = { kind = "move", commander = 3, route = { 4, 5 } }
store.orders_turn = 61
check("an unsent plan is consumed too", store.plan_consumed(61))
check("...leaving nothing staged", store.plan_count() == 0)

-- A plan with no turn against it cannot be stale: the HUD adopts the coming
-- turn on the frame anything is staged, so this is the pre-staging state.
reset()
store.orders[1] = { kind = "move", commander = 9, route = { 1 } }
check("a plan with no turn is left alone", not store.plan_consumed(99))
check("...and keeps its order", store.plan_count() == 1)

print("plan: signatures are stable and specific")
reset()
store.orders[1] = { kind = "move", commander = 1, route = { 3, 4 } }
local a = store.plan_signature()
check("the same plan signs the same twice", a == store.plan_signature())
store.orders[1].route = { 3, 5 }
check("a different route signs differently", a ~= store.plan_signature())
store.orders[1].route = { 3, 4 }
check("and back again", a == store.plan_signature())
store.orders[1].commander = 2
check("a different commander signs differently", a ~= store.plan_signature())


print("a turn is worth only so many orders")
do
	store.orders = {}
	store.game_view = {
		rates = {
			orders_per_turn = 3,
			order_cost = { move = 1, build = 1, recruit = 1, resupply = 1 },
		},
	}
	check("an empty plan has spent nothing", store.plan_spent() == 0)
	check("and the allowance comes from the server", store.plan_allowance() == 3)
	check("there is room at the start", store.plan_has_room("move"))

	store.orders = {
		{ kind = "move", commander = 1, route = { 2 } },
		{ kind = "build", at = 5, building = "yards" },
	}
	check("each staged order costs one", store.plan_spent() == 2)
	check("with room for one more", store.plan_has_room("build"))

	store.orders[3] = { kind = "resupply", commander = 1, units = 2 }
	check("a full turn has spent its allowance", store.plan_spent() == 3)
	check("and there is no room for a fourth", not store.plan_has_room("move"))

	-- Taking one back is what makes the allowance a decision rather than a wall.
	check("an order can be taken back", store.plan_remove(2))
	check("the plan is shorter for it", #store.orders == 2)
	check("and the one removed is the one that went",
		store.orders[2].kind == "resupply")
	check("which frees the allowance again", store.plan_has_room("move"))
	check("an index nobody staged is refused", not store.plan_remove(9))

	check("emptying the plan lets go of the turn it was for", (function()
		store.plan_remove(1)
		store.plan_remove(1)
		return #store.orders == 0 and store.orders_turn == nil
	end)())

	-- A client with no view yet must not silently refuse everything.
	store.game_view = nil
	check("without a view there is no allowance to spend against",
		store.plan_has_room("move"))
	store.orders = {}
end

if failures > 0 then
	print(string.format("\n%d PLAN TEST(S) FAILED", failures))
	os.exit(1)
end
print("\nALL PLAN TESTS PASSED")

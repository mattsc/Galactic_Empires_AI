-- Filters for which terrains produce how much food/gold
-- Done like this upfront so that it is only populated once
local terrain_production = {
    food = { toplevel_cfg.one_food_terrain, toplevel_cfg.two_food_terrain, toplevel_cfg.three_food_terrain },
    gold = { toplevel_cfg.one_gold_terrain, toplevel_cfg.two_gold_terrain, toplevel_cfg.three_gold_terrain }
}


local GEAI_utils = {}

function GEAI_utils.reset_vars(data)
    -- Note: because of how manual debug testing works, we cannot redefine the
    -- data variable here, but must set each key individually
    -- And possibly that's true for the AI also, not sure.

    -- This clears, among other things, data.GEAI_abort
    for k,v in pairs(data) do
        data[k] = nil
    end

    data.turn = wesnoth.current.turn
    data.turn_start_gold = wesnoth.sides[wesnoth.current.side].gold
    data.upgrades_gold = 0
    data.done_recruiting = false
end


-- Functions for showing the last AI moves from the menu options
function GEAI_utils.show_last_moves()
    local str = tostring(wml.variables.GEAI_last_ai_moves)
    wesnoth.interface.add_chat_message('Last AI moves', str)
    std_print(str)
end

function GEAI_utils.output_add_move(new_move)
    local str = tostring(wml.variables.GEAI_last_ai_moves) or ''

    -- Check whether this is the first move to be added this turn
    local i_str = string.find(str, 'Turn ' .. wesnoth.current.turn .. ':')
    if (not i_str) then
        str = 'Turn ' .. wesnoth.current.turn .. ':'
    end

    str = str .. '\n' .. new_move
    wml.variables.GEAI_last_ai_moves = str
end

function GEAI_utils.loc_str(loc, y)
    -- if loc is a number, it's the x value followed by the y value
    if (type(loc) == 'number') then
        return '[' .. loc .. ',' .. y .. ']'
    end

    local str = '['
    if loc.x then
        str = str .. loc.x .. ',' .. loc.y
    else
        str = str .. loc[1] .. ',' .. loc[2]
    end
    str = str .. ']'
    return str
end

function GEAI_utils.unit_str(unit, no_unit_str)
    if (not unit) then return no_unit_str or 'no unit' end
    local str = unit.id .. ' '
    if unit.name and (tostring(unit.name) ~= unit.id) then str = str .. '"' .. unit.name .. '"' .. ' ' end
    str = str ..  GEAI_utils.loc_str(unit)
    return str
end


-- Find how much food/gold a hex produces
function GEAI_utils.food_and_gold(x, y)
    --DBG.dbms(terrain_production, false, 'terrain_production')

    local food, gold = 0, 0

    for i = 1,3 do
        if wesnoth.map.matches(x, y , { terrain = terrain_production.food[i] }) then
            food = i
            break
        end
    end

    for i = 1,3 do
        if wesnoth.map.matches(x, y , { terrain = terrain_production.gold[i] }) then
            gold = i
            break
        end
    end

    return food, gold
end


-- Find the total food and gold production of a planet
function GEAI_utils.total_production(planet)
    local planet_hexes = GEAI_utils.get_planet_hexes(planet)

    local total_food, total_gold = 0, 0
    for _,hex in ipairs(planet_hexes) do
        local food, gold = GEAI_utils.food_and_gold(hex[1], hex[2])
        total_food = total_food + food
        total_gold = total_gold + gold
    end

    return total_food, total_gold
end


-- Force a gamestate change for AI actions that do not call one of the standard 'ai' table functions
function GEAI_utils.force_gamestate_change(ai)
    local unit = AH.get_units_with_moves { side = wesnoth.current.side }[1]
    if unit then
        local cfg_reset_moves = { id = unit.id, moves = unit.moves }
        ai.stopunit_moves(unit)
        wesnoth.sync.invoke_command('GEAI_reset_moves', cfg_reset_moves)
    else
        -- It is in principle possible that there are no units with moves left,
        -- but then the AI should be done anyway.
        -- Just putting a message here, to see if this ever happens.
        std_print('***** force_gamestate_change: no units with moves left *****')
    end
end


-- Find hexes on which the AI can recruit. Must be:
--  - next to a planet with a space dock
--  - not have a unit on them
function GEAI_utils.get_recruit_locs()
    local spacedocks = GEAI_utils.get_spacedocks { side = wesnoth.current.side }

    local available_castles = {}
    for _,spacedock in ipairs(spacedocks) do
        --std_print('spacedock: ' .. spacedock.id, spacedock.x .. ',' .. spacedock.y)

        local locs = wesnoth.map.find {
            include_borders = 'no',
            { "and", {
                x = spacedock.x, y = spacedock.y, radius = 5,
                { "filter_radius", { terrain = 'Zca' } }
            } },
            { "not", { -- empty hexes only
                { "filter", {} }
            } }
        }

        for _,loc in ipairs(locs) do
            table.insert(available_castles, loc)
        end

    end
    --std_print('#available_castles', #available_castles)

    return available_castles
end


-- Provide the filter for finding the hexes on a planet
function GEAI_utils.filter_planet_hexes(planet)
    return {
        x = planet.variables.hq_x,
        y = planet.variables.hq_y,
        radius = planet.variables.radius
    }
end


-- Get all the hexes on a planet
function GEAI_utils.get_planet_hexes(planet, filter)
    return wesnoth.map.find {
        { 'and', GEAI_utils.filter_planet_hexes(planet) },
        { 'and', filter }
    }
end


-- Get all the hexes containing artifacts
function GEAI_utils.get_artifact_locs(filter)
    return wesnoth.map.find {
        terrain = '*^Za*',
        { 'and', filter }
    }
end


------ Unit functions ------
-- Functions for finding specific types of units; function names should be self-explanatory
-- For units that can move, argument @with_moves_only can be passed, in which case
-- only units with MP left are found

-- This is a local utility function that is used by the others
local function get_units(filter, with_moves_only)
    if with_moves_only then
        return AH.get_units_with_moves(filter)
    else
        return wesnoth.units.find_on_map(filter)
    end
end

function GEAI_utils.get_scientists(filter, with_moves_only)
    return get_units({
        ability = 'science',
        { "and", filter }
    }, with_moves_only)
end

function GEAI_utils.get_workers(filter, with_moves_only)
    return get_units({
        ability = 'work',
        { "and", filter }
    }, with_moves_only)
end

-- For all ships, we also always check that they are not petrified
function GEAI_utils.get_ships(filter, with_moves_only)
    return get_units({
        role = 'ship',
        { 'not', { status = 'petrified' } },
        { "and", filter }
    }, with_moves_only)
end

function GEAI_utils.get_transports(filter, with_moves_only)
    return get_units({
        ability = 'transport',
        { 'not', { status = 'petrified' } },
        { "and", filter }
    }, with_moves_only)
end

-- This one includes petrified flagships
function GEAI_utils.get_flagships(filter, with_moves_only)
    return get_units({
        ability = 'flagship',
        { "and", filter }
    }, with_moves_only)
end

function GEAI_utils.get_headquarters(filter)
    return wesnoth.units.find_on_map {
        has_weapon = 'food',
        { "and", filter }
    }
end

function GEAI_utils.get_planets(filter)
    return wesnoth.units.find_on_map {
        role = 'planet',
        { "and", filter }
    }
end

function GEAI_utils.get_homeworlds(filter)
    local planets = GEAI_utils.get_planets(filter)
    local homeworlds = {}
    for _,planet in ipairs(planets) do
        if (planet.variables.colonised == 'homeworld') then
            table.insert(homeworlds, planet)
        end
    end
    return homeworlds
end

function GEAI_utils.get_planet_from_unit(unit)
    return wesnoth.units.find_on_map { id = unit.role }[1]
end

function GEAI_utils.get_units_on_planet(planet, filter, with_moves_only)
    return get_units({
        role = planet.id,
        { "and", filter }
    }, with_moves_only)
end

function GEAI_utils.get_spacedocks(filter)
    return wesnoth.units.find_on_map {
        ability = 'spacedock',
        { "and", filter }
    }
end


-- Maximum damage a unit can do
function GEAI_utils.unit_max_damage(unit)
    local max_damage = 0
    for _,attack in ipairs(unit.attacks) do
        local damage = attack.number * attack.damage
        if (damage > max_damage) then max_damage = damage end
    end
    return max_damage
end


-- Get the "power" of a unit, as per the definition in the equations below
function GEAI_utils.unit_power(unit)
    local max_damage = UTLS.unit_max_damage(unit)
    local hp_fraction = unit.hitpoints / unit.max_hitpoints
    local power = unit.hitpoints + max_damage * hp_fraction * 2
    return power
end

return GEAI_utils

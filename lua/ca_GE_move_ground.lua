----- CA: move_ground -----
--
-- Description:
--   Move units on the ground, including:
--   1. Move the workers on planets so that food/gold production is optimized.
--      The criterion for what optimized means can be configured using the 'food_value'
--      config parameter (see the config file for a description of the parameter).
--      Move all workers at the same time, to save evaluation time.
--      Only do a partial move, so that they can move again in case something changes.
--   2. Move injured units next to healers
--   3. If all hexes around an HQ are occupied, try to move a unit out of the way,
--      excluding workers (or 2 units, if the HQ has a cloner)
--   4. If enemy transports with passengers are within one move, move units away
--      from the corners

local ca_name = 'move_ground'

-- Rating only due to the production of the hexes, not taking other boni or penalties into account
local function production_rating(x, y, hex_info_map, total_food, total_gold, food_value)
    local food = GM.get_value(hex_info_map, x, y, 'food')
    if (not food) then return end
    local gold = hex_info_map[x][y].gold

    -- Base rating: simply the total production of the hex
    local rating = food + gold

    -- Negative config parameter 'food_value' means we simply maximize the total production
    if (food_value < 0) then return rating end

    local new_total_food = total_food + food
    local new_total_gold = total_gold + gold
    local optimal_gold = (new_total_food + new_total_gold) / ( 1 + food_value)
    local delta_gold = new_total_gold - optimal_gold

    -- Change base rating based on how far we are off from the desired food/gold ratio.
    -- If we are short on food production, we also multiply the rating by 'food_value'.
    -- Note that delta_rating is always <= 0
    local delta_rating
    if (delta_gold > 0) then -- more gold than wanted
        delta_rating = - delta_gold * food_value
    else -- less gold than wanted
        delta_rating = delta_gold
    end
    delta_rating = delta_rating / 2

    rating = rating + delta_rating

    return rating
end


local moves_found
local ca_GE_move_ground = {}

function ca_GE_move_ground:evaluation(cfg, data)
    local ca_score = CFG.get_cfg_parm('CA_scores')[ca_name]
    if (ca_score < 0) or data.GEAI_abort then return 0 end

    local start_time = wesnoth.ms_since_init() / 1000.
    DBG.print_debug_eval(ca_name, 0, start_time, 'begin eval')


    moves_found = {}

    local all_workers = UTLS.get_workers { side = wesnoth.current.side }
    --std_print('#all_workers', #all_workers)

    -- Eligible workers to be moved must:
    --  - have moves left
    --  - not be injured
    --  - not be next to an enemy, but that's a requirement on the hexes (done later)
    local worker_planets, worker_noMP_planets = {}, {}
    for _,unit in ipairs(all_workers) do
        --std_print(UTLS.unit_str(unit), unit.moves, unit.role)
        if (unit.hitpoints == unit.max_hitpoints) then
            if (unit.moves > 0) then
                if (not worker_planets[unit.role]) then
                    worker_planets[unit.role] = {}
                end
                table.insert(worker_planets[unit.role], { id = unit.id })
            else
                -- We also need these to calculate total worker production
                if (not worker_noMP_planets[unit.role]) then
                    worker_noMP_planets[unit.role] = {}
                end
                table.insert(worker_noMP_planets[unit.role], { id = unit.id, x = unit.x, y = unit.y })
            end
        end
    end
    --DBG.dbms(worker_planets, false, 'worker_planets')
    --DBG.dbms(worker_noMP_planets, false, 'worker_noMP_planets')

    for planet_id,workers in pairs(worker_planets) do
        local planet = wesnoth.units.find_on_map { id = planet_id }[1]
        local hq = wesnoth.units.get(planet.variables.hq_x, planet.variables.hq_y)

        -- If there are enemy ships next to the planet, it is blockaded
        --  --> it will not produce gold --> raise food value
        local adj_enemy_ships = UTLS.get_ships {
            { 'filter_side', { { 'enemy_of', {side = wesnoth.current.side } } } },
            { 'filter_location', { x = planet.x, y = planet.y, radius = 1 } }
        }
        --std_print('#adj_enemy_ships', #adj_enemy_ships, UTLS.unit_str(planet))

        local food_value = CFG.get_cfg_parm('food_value')
        if (#adj_enemy_ships > 0) then food_value = 100 end

        -- Increase food production if the planet is at less than half its maximum population
        if (hq.variables.population_current < hq.variables.population_max / 2) then
            local factor = (2 - 2 * hq.variables.population_current / hq.variables.population_max)^2
            food_value = food_value * factor
            --std_print(hq.variables.population_current, hq.variables.population_max, factor, food_value)
        end
        --std_print('food_value: ' .. food_value)


        -- All planet hexes that can produce food or gold. This excludes hexes
        -- with enemies, and adjacent to enemies.
        -- We set this up in a map (hex_info_map) for speed reasons and, more importantly,
        -- so that we do not need to check for every unit whether hexes are excluded from
        -- production, e.g. due to adjacent enemies.
        local planet_hexes = UTLS.get_planet_hexes(planet, {
            { 'not', { -- cannot have an enemy on it
                { 'filter', {
                    { 'filter_side', { { 'enemy_of', {side = wesnoth.current.side } } } }
                } }
            } },
            { 'not', { -- cannot be adjacent to an enemy
                { 'filter_adjacent_location', {
                { 'filter', {
                    { 'filter_side', { { 'enemy_of', {side = wesnoth.current.side } } } }
                } }
                } }
            } }
        })
        --std_print(UTLS.unit_str(planet) .. ': ' .. #planet_hexes .. ' hexes')

        local hex_info_map = {}
        for _,hex in ipairs(planet_hexes) do
            local food, gold = UTLS.food_and_gold(hex[1], hex[2])
            --std_print('  ' .. UTLS.loc_str(hex) .. ': ' .. food .. ' food, ' .. gold .. ' gold')

            -- Hexes adjacent to the HQ get a penalty, as new citizens are only produced on those
            if (wesnoth.map.distance_between(hq.x, hq.y, hex[1], hex[2]) == 1) then
                food = (food or 0) - 0.75
            end

            -- Beam-down hexes also get a penalty, as units can be auto-killed by enemies beaming down on them there
            local dirs = { 'n', 'ne', 'se', 's', 'sw', 'nw' }
            for _,dir in ipairs(dirs) do
                if (hex[1] == planet.variables[dir .. '_x']) and (hex[2] == planet.variables[dir .. '_y']) then
                    food = (food or 0) - 0.9
                end
            end

            GM.set_value(hex_info_map, hex[1], hex[2], 'food', food)
            hex_info_map[hex[1]][hex[2]].gold = gold
        end

        -- How much food do workers without MP produce. This is needed to find
        -- the correct food/good ratio for the planet.
        local total_food, total_gold = 0, 0
        for _,unit in ipairs(worker_noMP_planets[planet_id] or {}) do
            total_food = total_food + (GM.get_value(hex_info_map, unit.x, unit.y, 'food') or 0)
            total_gold = total_gold + (GM.get_value(hex_info_map, unit.x, unit.y, 'gold') or 0)
        end
        --std_print(UTLS.unit_str(planet) .. ' starting total food, gold: ' .. total_food, total_gold)

        -- Also add information about units on each hex, so that it has to be done only once.
        -- Plus, we add the (initial) rating of the hex each unit is on. This is done for
        -- and initial sorting of the units, to avoid unnecessary shuffling as much as possible.
        for _,hex in ipairs(planet_hexes) do
            local unit_in_way = wesnoth.units.get(hex[1], hex[2])
            if unit_in_way then
                hex_info_map[hex[1]][hex[2]].id = unit_in_way.id

                -- Add a flag whether the unit can move out of the way
                local reachmap = AH.get_reachmap(unit_in_way, { exclude_occupied = true })
                if (reachmap:size() > 1) then
                    hex_info_map[hex[1]][hex[2]].can_move_away = true
                else
                    hex_info_map[hex[1]][hex[2]].can_move_away = false
                end

                -- Also add the rating of the hex a unit is on to the worker table
                for _,worker in ipairs(workers) do
                    if (worker.id == unit_in_way.id) then
                        worker.unit_rating = production_rating(hex[1], hex[2], hex_info_map, total_food, total_gold, food_value)
                    end
                end
            end
        end
        --DBG.dbms(hex_info_map)
        --DBG.show_gm_with_message(hex_info_map, 'food', 'hex_info_map: food', { x = hq.x, y = hq.y })
        --DBG.show_gm_with_message(hex_info_map, 'gold', 'hex_info_map: gold', { x = hq.x, y = hq.y })
        --DBG.show_gm_with_message(hex_info_map, 'id', 'hex_info_map: unit in way', { x = hq.x, y = hq.y })
        --DBG.show_gm_with_message(hex_info_map, 'can_move_away', 'hex_info_map: can move away', { x = hq.x, y = hq.y })

        -- Add (bad) ratings for all units that do not already have one.
        -- This can happen, for example, if a worker is on a hex next to an enemy.
        for _,worker in ipairs(workers) do
            if (not worker.unit_rating) then worker.unit_rating = -100 end
        end

        -- Now presort the workers; as all healthy workers are equivalent, we can
        -- simply start with those already on good terrain and use a greedy algorithm.
        -- If we order from lowest to highest instead, there can be a lot of shuffling back and forth.
        table.sort(workers, function(a, b) return a.unit_rating > b.unit_rating end)
        --DBG.dbms(workers)

        local workers_by_id = {}
        for _,worker in ipairs(workers) do
            workers_by_id[worker.id] = true
        end

        local moves_this_planet = {}
        for _,worker in ipairs(workers) do
            --std_print(UTLS.unit_str(worker))
            local unit = wesnoth.units.find_on_map { id = worker.id }[1]
            local reach = wesnoth.paths.find_reach(unit)
            --std_print('  #reach: ' .. #reach)

            local unit_rating_map = {}
            local max_rating, best_loc = - math.huge
            for _,loc in ipairs(reach) do
                -- production_rating() returns nil for hexes that were previously excluded,
                -- for example, those next to enemies.
                local rating = production_rating(loc[1], loc[2], hex_info_map, total_food, total_gold, food_value)
                if rating then
                    -- Give a penalty for occupied hexes:
                    -- Small penalty for non-worker units
                    -- Very large penalty for other workers also being considered this move,
                    -- to avoid moving out of the way and not being able to get to good terrain after
                    local uiw_id = hex_info_map[loc[1]][loc[2]].id
                    local can_move_away = hex_info_map[loc[1]][loc[2]].can_move_away
                    if (not uiw_id) or (uiw_id == unit.id) or can_move_away then
                        if can_move_away then
                            if workers_by_id[uiw_id] and (uiw_id ~= unit.id) then
                                rating = rating - 1000
                            else
                                rating = rating - 0.1
                            end
                        end

                        -- Small bonus for shortest distance moved
                        rating = rating + 0.01 * loc[3]

                        if (rating > max_rating) then
                            max_rating = rating
                            best_loc = loc
                        end

                        GM.set_value(unit_rating_map, loc[1], loc[2], 'rating', rating)
                    end
                end
            end
            --DBG.show_gm_with_message(unit_rating_map, 'rating', 'unit_rating_map', unit)

            -- We do not insert a move if best_hex is the hex the unit is on already,
            -- but we still count its production.
            if best_loc then
                total_food = total_food + hex_info_map[best_loc[1]][best_loc[2]].food
                total_gold = total_gold + hex_info_map[best_loc[1]][best_loc[2]].gold
                --std_print('  ' .. UTLS.unit_str(unit) .. ' food, gold: ' .. hex_info_map[best_loc[1]][best_loc[2]].food, hex_info_map[best_loc[1]][best_loc[2]].gold)
                if ((best_loc[1] ~= unit.x) or (best_loc[2] ~= unit.y)) then
                    table.insert(moves_this_planet, {
                        id = unit.id,
                        src = { unit.x, unit.y },
                        dst = best_loc,
                        partial_move = true
                    })
                    -- Need to mark the new hex as occupied now, with unit not being able to move out of the way,
                    -- as we are still going through the rest of the workers afterward
                    hex_info_map[best_loc[1]][best_loc[2]].id = unit.id
                    hex_info_map[best_loc[1]][best_loc[2]].can_move_away = false

                    -- And finally, mark the one the unit was on as unoccupied
                    -- Need to use the function for this, as this field might not exist in the table
                    GM.set_value(hex_info_map, unit.x, unit.y, 'id', nil)
                    GM.set_value(hex_info_map, unit.x, unit.y, 'can_move_away', nil)
                end
            end
        end
        --std_print(UTLS.unit_str(planet) .. ' total food, gold: ' .. total_food, total_gold)

        -- Prevent shuffling: only do this if this results in a different food
        -- or gold production than the current unit locations
        -- Note: don't need to rearrange the ids in hex_info_map even if we abort
        -- the moves as we are done with this planet
        local old_food, old_gold, new_food, new_gold = 0, 0, 0, 0
        for _,this_move in ipairs(moves_this_planet) do
            old_food = old_food + (hex_info_map[this_move.src[1]][this_move.src[2]].food or 0)
            old_gold = old_gold + (hex_info_map[this_move.src[1]][this_move.src[2]].gold or 0)
            new_food = new_food + (hex_info_map[this_move.dst[1]][this_move.dst[2]].food or 0)
            new_gold = new_gold + (hex_info_map[this_move.dst[1]][this_move.dst[2]].gold or 0)
        end
        --std_print('old_food, old_gold, new_food, new_gold', old_food, old_gold, new_food, new_gold)

        if (old_food ~= new_food) or (old_gold ~= new_gold) then
            for _,this_move in ipairs(moves_this_planet) do
                table.insert(moves_found, this_move)
            end
        end
    end
    --DBG.dbms(moves_found, false, 'moves_found')

    if moves_found[1] then
        DBG.print_debug_eval(ca_name, ca_score, start_time, #moves_found .. ' workers found to be moved')
        return ca_score
    else
        DBG.print_debug_eval(ca_name, 0, start_time, 'no qualifying workers found to be moved')
    end


    local headquarters = UTLS.get_headquarters { side = wesnoth.current.side }
    --std_print('#headquarters: ' .. #headquarters)


    -- Move injured units toward healers
    for _,hq in pairs(headquarters) do
        local planet = UTLS.get_planet_from_unit(hq)
        --std_print(UTLS.unit_str(hq), UTLS.unit_str(planet))
        -- Find all units on a planet that are injured and do not regenerate
        local planet_units = UTLS.get_units_on_planet(planet, {
            side = wesnoth.current.side,
            { 'not', { id = hq.id } },
            { 'not', { ability_type = 'regenerate' } }
        })
        local injured_units = {}
        --std_print('  injured units:')
        for _,unit in ipairs(planet_units) do
            if ((unit.hitpoints < unit.max_hitpoints) or unit.status.poisoned)
                and (unit.moves > 0)
            then
                --std_print('    ' .. UTLS.unit_str(unit))
                table.insert(injured_units, unit)
            end
        end
        --std_print('  #injured_units: ' .. #injured_units)

        -- Find potential healers
        if (#injured_units > 0) then
            --std_print('  healers:')
            local healers_organic = UTLS.get_units_on_planet(planet, {
                side = wesnoth.current.side,
                ability = 'hospital,medic4,medic6,medic8'
            })
            --std_print('  #healers_organic: ' .. #healers_organic)
            local healers_mechanic = UTLS.get_units_on_planet(planet, {
                side = wesnoth.current.side,
                role = hq.role,
                ability = 'hospital,g_repair4,g_repair8'
            })
            --std_print('  #healers_mechanic: ' .. #healers_mechanic)

            local planet_hexes = UTLS.get_planet_hexes(planet)
            --std_print('  #planet_hexes ' .. UTLS.unit_str(planet) .. ': ' .. #planet_hexes)
            local healing_hexes = {}
            for _,loc in ipairs(planet_hexes) do
                if (wesnoth.terrain_types[wesnoth.current.map[loc]].healing > 0) then
                    table.insert(healing_hexes, loc)
                end
            end
            --std_print('  #healing_hexes ' .. UTLS.unit_str(planet) .. ': ' .. #healing_hexes)

            -- Now find healing healing locations for each unit
            -- We do that one at a time, so that they don't interfere with each other
            for _,unit in ipairs(injured_units) do
                local healers = healers_organic
                if (unit.race == 'building') or (unit.race == 'vehicle') or (unit.race == 'robot') then
                    healers = healers_mechanic
                end

                local healing_locs = {}
                for _,healer in ipairs(healers) do
                    for xa,ya in H.adjacent_tiles(healer.x, healer.y) do
                        local unit_in_way = wesnoth.units.get(xa, ya)
                        if (not unit_in_way) or (unit_in_way.id == unit.id) then
                            table.insert(healing_locs, { xa, ya })
                        end
                    end
                end
                for _,loc in ipairs(healing_hexes) do
                    local unit_in_way = wesnoth.units.get(loc[1], loc[2])
                    if (not unit_in_way) or (unit_in_way.id == unit.id) then
                        table.insert(healing_locs, loc)
                    end
                end
                --DBG.dbms(healing_locs, false, 'healing_locs')

                local min_cost, best_hex = math.huge
                for _,loc in ipairs(healing_locs) do
                    local _,cost = wesnoth.paths.find_path(unit, loc[1], loc[2])
                    if (cost < min_cost) then
                        min_cost = cost
                        best_hex = loc
                    end
                end

                if best_hex then
                    --std_print('    best: ' .. UTLS.unit_str(unit) .. ' --> ' .. UTLS.loc_str(best_hex))
                    table.insert(moves_found, {
                        id = unit.id,
                        src = { unit.x, unit.y },
                        dst = best_hex,
                        partial_move = false
                    })
                    -- We do one healer at a time, so that they don't interfere with each other
                    break
                end
            end
        end
    end
    --DBG.dbms(moves_found, false, 'moves_found')

    if moves_found[1] then
        DBG.print_debug_eval(ca_name, ca_score, start_time, 'found injured unit to be moved toward healer')
        return ca_score
    else
        DBG.print_debug_eval(ca_name, 0, start_time, 'no qualifying injured unit moves found')
    end


    -- Check if the are enough empty tiles around the HQs (one normally,
    -- two if HQ has a cloner). If not, try to move a unit out of the way.
    -- We only move one unit per call, in order to avoid them going for the same hex.
    -- If that proves too expensive, we can consider units in combination later.
    for _,hq in pairs(headquarters) do
        local n_available = 0
        for xa,ya in H.adjacent_tiles(hq.x, hq.y) do
            local unit = wesnoth.units.get(xa, ya)
            if (not unit) then
                n_available = n_available + 1
            end
        end
        local n_needed = 1
        if hq.variables.cloner then n_needed = 2 end
        --std_print('n_available, n_needed', n_available, n_needed)

        -- Only if that is the case (in order to save calculation time in most
        -- circumstances), check where units can move to
        if (n_available < n_needed) then
            local max_rating, best_move, best_unit = -math.huge
            for xa,ya in H.adjacent_tiles(hq.x, hq.y) do
                -- Consider all units on AI side with moves left
                -- Need to exclude workers, as they do only partial moves above
                -- Do not need to exclude injured units, as those do full moves
                local unit = wesnoth.units.get(xa, ya)
                if unit and (unit.moves > 0)
                    and unit:matches { side = wesnoth.current.side, { 'not', { ability = 'work' } } }
                then
                    --std_print(UTLS.loc_str(xa, ya) .. ': ' .. UTLS.unit_str(unit))
                    local reach = wesnoth.paths.find_reach(unit)
                    for _,r in ipairs(reach) do
                        local unit_in_way = wesnoth.units.get(r[1], r[2])
                        --std_print(r[1], r[2], r[3], UTLS.unit_str(unit_in_way))
                        if (not unit_in_way) then -- this also excludes the hex the unit is on itself
                            local rating = r[3]
                            if (rating > max_rating) then
                                max_rating = rating
                                best_move = { r[1], r[2] }
                                best_unit = unit
                            end
                        end
                    end
                end
            end

            if best_move then
                table.insert(moves_found, {
                    id = best_unit.id,
                    src = { best_unit.x, best_unit.y },
                    dst = best_move,
                    partial_move = true
                })
            end
        end
    end
    --DBG.dbms(moves_found, false, 'moves_found')

    if moves_found[1] then
        DBG.print_debug_eval(ca_name, ca_score, start_time, #moves_found .. ' units found to move away from HQ')
        return ca_score
    else
        DBG.print_debug_eval(ca_name, 0, start_time, 'no qualifying moves away from HQs found')
    end


    -- If enemy transports with passengers are within one move, move units away from the beam-down hexes
    -- Check all planets, not just AI-owned
    local enemy_transports = AH.get_attackable_enemies { ability = 'transport' }
    local planets = UTLS.get_planets()
    local dirs = { 'n', 'ne', 'se', 's', 'sw', 'nw' }

    for _,planet in ipairs(planets) do
        --std_print(UTLS.unit_str(planet))

        -- Checking for distance between transports and planet first, because it's fastest, then
        -- finding units in the corners, then path finding for the transports
        local close_transports = {}
        for _,transport in ipairs(enemy_transports) do
            if (wesnoth.map.distance_between(planet, transport) <= transport.max_moves + 1)
                and (transport.attacks[1].damage > 0)
            then
                table.insert(close_transports, transport)
                --std_print('    close transport: ' .. UTLS.unit_str(transport))
            end
        end
        --std_print('  #close_transports: ' .. #close_transports)

        if (#close_transports > 0) then
            local units = UTLS.get_units_on_planet(planet, { side = wesnoth.current.side }, true )

            local corner_units = {}
            for _,unit in ipairs(units) do
                for _,dir in ipairs(dirs) do
                    if (unit.x == planet.variables[dir .. '_x']) and (unit.y == planet.variables[dir .. '_y']) then
                        table.insert(corner_units, unit)
                        --std_print('    corner unit: ' .. UTLS.unit_str(unit))
                        break
                    end
                end
            end
            --std_print('  #corner_units: ' .. #corner_units)

            if (#corner_units > 0) then
                --std_print('  checking threats')
                local is_threat = false
                for _,transport in ipairs(close_transports) do
                    for xa,ya in H.adjacent_tiles(planet.x, planet.y) do
                        -- ignore units, as some defenders may be killed by enemy ships
                        local _,cost = wesnoth.paths.find_path(transport, xa, ya, { ignore_units = true })
                        --std_print('    ' .. UTLS.loc_str({ xa, ya }), cost)

                        if (cost <= transport.max_moves ) then
                            --std_print('    is threat: ' .. UTLS.unit_str(transport))
                            is_threat = true
                            break
                        end
                    end
                    if is_threat then break end
                end

                if is_threat then
                    --std_print('  trying to move units')

                    for _,unit in ipairs(corner_units) do
                        local max_rating, best_move = -math.huge
                        local reach = wesnoth.paths.find_reach(unit)
                        for _,r in ipairs(reach) do
                            local unit_in_way = wesnoth.units.get(r[1], r[2])
                            --std_print(r[1], r[2], r[3], UTLS.unit_str(unit_in_way))
                            if (not unit_in_way) then -- this also excludes the hex the unit is on itself
                                local rating = r[3]
                                if (rating > max_rating) then
                                    max_rating = rating
                                    best_move = { r[1], r[2] }
                                end
                            end
                        end

                        if best_move then
                            table.insert(moves_found, {
                                id = unit.id,
                                src = { unit.x, unit.y },
                                dst = best_move,
                                partial_move = true
                            })
                        end
                    end
                end
            end
        end
    end

    if moves_found[1] then
        DBG.print_debug_eval(ca_name, ca_score, start_time, #moves_found .. ' units found to move away from beam-down hexes')
        return ca_score
    end

    DBG.print_debug_eval(ca_name, 0, start_time, 'no qualifying moves away from beam-down hexes found')
    return 0
end

function ca_GE_move_ground:execution(cfg, data, ai_debug)
    local ai = ai or ai_debug

    for _,move in ipairs(moves_found) do
        local unit = wesnoth.units.find_on_map { id = move.id }[1]

        local str = 'move ' .. UTLS.unit_str(unit) .. '  -->  ' .. UTLS.loc_str(move.dst)
        DBG.print_debug_exec(ca_name, str)
        UTLS.output_add_move(str)

        AH.robust_move_and_attack(ai, unit, move.dst, nil, { partial_move = move.partial_move })
    end

    moves_found = {}
end

return ca_GE_move_ground

----- CA: transport_troops -----
--
-- Description:
--  Move ground troops between planets. This includes:
--   - recruit more transports, if needed
--   - move transports to planets to pickup units
--   - beam up units
--   - move transports to the dropoff planets
--   - beam down units

local ca_name = 'transport_troops'

local function are_variables_set(transport, purpose, goal_id, pickup_id)
    return (transport.variables.GEAI_purpose == purpose)
        and (transport.variables.GEAI_goal_id == goal_id)
        and (transport.variables.GEAI_pickup_id == pickup_id)
end


local function get_beam_down_loc(planet, transport)
    -- Returns the location on the planet to which a passenger would beam down to,
    -- as well as the unit at that location (or nil if there isn't one)
    -- and the direction string used for the beaming event

    local direction = wesnoth.map.get_relative_dir({ planet.x, planet.y }, { transport.x, transport.y })
    local beam_loc = { planet.variables[direction .. '_x'], planet.variables[direction .. '_y'] }
    local unit_in_way = wesnoth.units.get(beam_loc[1], beam_loc[2])

    return beam_loc, unit_in_way, direction
end


local function add_combat_rating(available_units)
    -- Set combat rating for units, including bonus by population type
    for _,unit_infos in pairs(available_units) do
        for _,unit_info in pairs(unit_infos) do
            local rating = 1 + unit_info.power / 1000

            -- Since transports heal, and injured units cannot work or do science,
            -- prefer injured units. Note that unit power is reduced when they are
            -- injured, so this contribution needs to be stronger than that
            rating = rating + unit_info.hp_missing / 100

            if (unit_info.type == 'combat_unit') then
                rating = rating * 1.5
            elseif (unit_info.type == 'science_unit') then
                rating = rating * 1.2
            end
            unit_info.rating = rating
        end
    end
end


local function add_available_unit(available_units, container_id, unit)
    -- Add a unit to the @available_units array, together with its power and population type
    -- @container_id: the id of the unit that currently contains @unit (can be a planet or a transport)

    local available_unit = {
        id = unit.id,
        power = UTLS.unit_power(unit),
        hp_missing = unit.max_hitpoints - unit.hitpoints
    }

    if unit:matches { ability = 'work' } then
        available_unit.type = 'work_unit'
    elseif unit:matches { ability = 'science' } then
        available_unit.type = 'science_unit'
    else
        available_unit.type = 'combat_unit'
    end

    if (not available_units[container_id]) then available_units[container_id] = {} end
    table.insert(available_units[container_id], available_unit)
end


local function find_best_troops(available_units, power_needed, capacity)
    -- Determine which and how many of @available_units are needed in order to
    -- get to @power_needed. Also return their combined rating, number and power.
    -- @capacity: available space (number of units) on the transport under consideration

    -- The input @available_units may or may not be sorted by rating
    -- Note that this also sorts the array in the calling function, which means that we
    -- do not need to return an array with the best units, but simply how many are to be used
    table.sort(available_units, function(a, b) return a.rating > b.rating end)

    local n_units, power_assigned, rating = 0, 0, 0
    while (n_units < #available_units) and (n_units < capacity) and (power_assigned < power_needed) do
        n_units = n_units + 1
        power_assigned = power_assigned + available_units[n_units].power
        rating = rating + available_units[n_units].rating
    end

    -- Rating needs to be divided by number of units, otherwise it will
    -- always be higher for more units, even if they are worse on average
    rating = rating / n_units

    return rating, n_units, power_assigned
end


local function set_assignment(assignments, instructions, transport_id, goal_id, pickup_id)
    -- Only set the assignment if there is actually something to do that changes the gamestate
    -- However, this function also changes the instructions table and that
    -- needs to be done independent of whether the gamestate is changed

    -- Setting the unit variables counts as changing the gamestate
    -- Assigned units are not stored in the transport's variable, but reassigned each turn.

    local transport = wesnoth.units.find_on_map { id = transport_id }[1]
    local goal_planet = wesnoth.units.find_on_map { id = goal_id }[1]

    local changes_state = false
    if (transport.moves > 0) then
        --std_print(UTLS.unit_str(transport) .. ' has moves left')
        changes_state = true
    elseif (wesnoth.map.distance_between(goal_planet.x, goal_planet.y, transport.x, transport.y) == 1) then
        -- Transport is next to goal planets, meaning it is ready to beam down a unit
        -- Do not have to check that there are passengers on it as the transport's
        -- assignment is deleted once units have beamed down.
        -- However, we do need to check that the beam-down location is available: it can
        -- at most have an own unit on it that can move out of the way, or a non-friendly enemy unit
        local beam_loc, unit_in_way = get_beam_down_loc(goal_planet, transport)
        if unit_in_way then
            if wesnoth.sides.is_enemy(unit_in_way.side, wesnoth.current.side)
                and (not unit_in_way:matches { ability = 'friendly' })
            then
                changes_state = true
            elseif (unit_in_way.side == wesnoth.current.side) then
                local reachmap = AH.get_reachmap(unit_in_way, { exclude_occupied = true })
                if (reachmap:size() > 1) then
                    changes_state = true
                end
            end
        else
            changes_state = true
        end
        --std_print(UTLS.unit_str(transport) .. ' is at goal planet, changes_state:', changes_state)
    elseif (not are_variables_set(transport, instructions.settings.purpose, goal_id, pickup_id)) then
        --std_print(UTLS.unit_str(transport) .. ' needs variables changed')
        changes_state = true
    end

    local power_needed = instructions.settings.power_desired or instructions.power_needed[goal_id]
    local passenger_power = instructions.available_power[transport.id] or 0
    local power_missing = power_needed - passenger_power
    local capacity = transport.attacks[1].number - transport.attacks[1].damage

    -- If there are passengers on the transport, those always get assigned
    local assigned_unit_ids = {}
    if (passenger_power > 0) then
        for _,passenger in ipairs(instructions.available_units[transport.id]) do
        table.insert(assigned_unit_ids, passenger.id)
        end
    end

    -- Check what other units need to be picked up.
    -- We always need to check whether there is a pickup planet, because the power on
    -- the goal planet may have changed while the transport was en route (meaning that
    -- both more or less power may be needed now).
    if pickup_id and (capacity > 0) then
        local unit_rating, n_units, power_assigned = find_best_troops(instructions.available_units[pickup_id], power_missing, capacity)
        passenger_power = passenger_power + power_assigned
        --std_print(UTLS.unit_str(transport), goal_id, pickup_id, unit_rating, n_units, power_assigned, power_missing)

        for i = 1,n_units do
            table.insert(assigned_unit_ids, instructions.available_units[pickup_id][1].id)
            table.remove(instructions.available_units[pickup_id], 1)
        end
        instructions.available_power[pickup_id] = instructions.available_power[pickup_id] - power_assigned

        if (instructions.available_power[pickup_id] <= 0) then
            instructions.available_units[pickup_id] = nil
            instructions.available_power[pickup_id] = nil
        end
    end

    if (not instructions.power_assigned) then instructions.power_assigned = {} end
    instructions.power_assigned[goal_id] = (instructions.power_assigned[goal_id] or 0) + passenger_power

    -- All of the above needs to be done independent of whether the gamestate is
    -- changed, but the assignment itself only gets added if it does
    if (not changes_state) then return end


    if (not assignments[instructions.settings.purpose]) then assignments[instructions.settings.purpose] = {} end
    table.insert(assignments[instructions.settings.purpose], {
        transport_id = transport_id,
        goal_id = goal_id,
        pickup_id = pickup_id,
        assigned_unit_ids = assigned_unit_ids
    })
end


local function find_assignments(assignments, transports, instructions, planets_by_id)
    local dist_ratings = {}
    for _,transport in ipairs(transports) do
        local passenger_power = instructions.available_power[transport.id] or 0
        local capacity = transport.attacks[1].number - transport.attacks[1].damage
        --std_print(UTLS.unit_str(transport) .. ': passenger_power ' .. passenger_power .. '; capacity ' .. transport.attacks[1].number - transport.attacks[1].damage .. '; moves ' .. transport.moves)
-- xxxx goal planet must have space to beam down to

        -- First calculate just the distance rating, as that is somewhat expensive and does
        -- not change as transports are assigned one by one
        for goal_planet_id,power_needed in pairs(instructions.power_needed) do
            local power_assigned = instructions.power_assigned and instructions.power_assigned[goal_planet_id] or 0
            --std_print('  goal planet: ' .. goal_planet_id, power_needed, power_assigned)
            -- Only consider planets that do not have enough power assigned yet
            if (power_needed > power_assigned) then
                local goal_planet = planets_by_id[goal_planet_id]
                --std_print('    goal planet: ' .. UTLS.unit_str(goal_planet))

                -- Transports with passengers on them can go straight to the goal planet
                if (passenger_power > 0) then
                    local dist = wesnoth.map.distance_between(goal_planet.x, goal_planet.y, transport.x, transport.y)
                    dist = dist - 2
                    if (dist <= 1) then dist = 1 end
                    dist = dist / transport.max_moves
                    if (not dist_ratings[transport.id]) then dist_ratings[transport.id] = {} end
                    if (not dist_ratings[transport.id].self) then dist_ratings[transport.id].self = {} end
                    dist_ratings[transport.id]['self'][goal_planet.id] = 1 / dist
                -- While those without need to pick up troops at a pickup planet first
                end

                -- All transports with capacity left (incl. those that already have passengers)
                -- might want/need to go to a pickup planet first
                if (capacity > 0) then
                    for _,pickup_planet in pairs(planets_by_id) do
                        local available_power = instructions.available_power[pickup_planet.id] or 0
                        if (available_power > 0) then
                            --std_print('  pickup: ' .. UTLS.unit_str(pickup_planet), available_power)
                            local dist = wesnoth.map.distance_between(pickup_planet.x, pickup_planet.y, transport.x, transport.y)
                            -- -1 because we only need to move next to the planet
                            dist = dist - 1
                            if (dist <= 1) then dist = 1 end

                            local dist2 = wesnoth.map.distance_between(pickup_planet.x, pickup_planet.y, goal_planet.x, goal_planet.y)
                            if (dist2 <= 1) then dist2 = 1 end

                            dist = (dist + dist2) / transport.max_moves
                            if (not dist_ratings[transport.id]) then dist_ratings[transport.id] = {} end
                            if (not dist_ratings[transport.id][pickup_planet.id]) then dist_ratings[transport.id][pickup_planet.id] = {} end
                            -- Won't bother with the exact geometry for this
                            dist_ratings[transport.id][pickup_planet.id][goal_planet.id] = 1 / dist
                        end
                    end
                end
            end
        end
    end
    --DBG.dbms(dist_ratings, false, 'dist_ratings')

    -- Now assign transports until we either have enough or none are left
    -- The assigned power changes as we go through this, so the rest of the rating
    -- needs to be done one by one
    while (instructions.settings.n_needed > instructions.n_assigned) and next(dist_ratings) do
        --std_print('next assignment:')
        local max_rating = - math.huge
        local best_id, best_pickup_id, best_goal_id
        for transport_id,transport_ratings in pairs(dist_ratings) do
            local transport = wesnoth.units.find_on_map { id = transport_id }[1]
            local capacity = transport.attacks[1].number - transport.attacks[1].damage
            local passenger_power = instructions.available_power[transport.id] or 0

            for pickup_id,pickup_planet_ratings in pairs(transport_ratings) do
                for goal_id,dist_rating in pairs(pickup_planet_ratings) do
                    -- Desired power is set for all planets equally (such as when there
                    -- are aliens on some, but not all planets). By contrast, needed power
                    -- is what is actually needed on each individual planet.
                    local power_needed = instructions.power_needed[goal_id]
                    local power_desired = instructions.settings.power_desired or power_needed

                    local power_assigned = instructions.power_assigned and instructions.power_assigned[goal_id] or 0
                    local power_missing = power_desired - power_assigned
                    --std_print(UTLS.unit_str(transport), pickup_id, goal_id, power_desired, power_missing)

                    local rating
                    if (power_missing > 0) then
                        local available_id = pickup_id
                        if (pickup_id == 'self') then
                            available_id = transport.id
                        end

                        local unit_rating, n_units, new_power_assigned = find_best_troops(instructions.available_units[available_id], power_missing, capacity)

                        -- Prefer transport/planet pairs that will provide a large fraction of the power needed
                        local completion_rating = (power_assigned + new_power_assigned + passenger_power) / power_desired
                        if (completion_rating > 1) then completion_rating = 1 end

                        -- Also prefer transports that transport more units
                        local n_unit_rating = 1 + n_units / 10

                        -- Add a stiff penalty for assignments that do not provide the required power
                        -- and do not involve at least 3 passengers
                        -- This results in these not being used unless there is no other option
                        -- Also, if 'enough_power_only' is set, completely disable those.
                        -- This is used mostly for colonising planets with aliens.
                        local penalty = 0
                        if (completion_rating < 1) then
                            -- This uses power_needed, while completion_rating uses power_desired
                            local real_power_missing = power_needed - power_assigned - new_power_assigned - passenger_power
                            if instructions.settings.enough_power_only and (real_power_missing > 0) then
                                penalty = -1000
                            elseif (n_units < 3) then
                                penalty = -10
                            end
                        end

                        if (penalty > -1000) then
                            rating = dist_rating * completion_rating * unit_rating * n_unit_rating + penalty
                        end

                        --std_print(string.format('%.3f * %.3f * %.3f * %.3f  + %3d  =  %.3f    <-- %-45s: %12s -> %-12s %.1f/%.1f',
                        --    dist_rating, completion_rating, unit_rating, n_unit_rating, penalty, (rating or -999), UTLS.unit_str(transport), pickup_id, goal_id, power_desired-power_missing, power_desired))
                    else
                        -- Not sure if we'll ever get to the point where we have transports
                        -- left, but no planet where they are needed
                        -- But just in case we do, simply use the distance rating, but strongly derated
                        -- so that this is not used if there are still planets left that need power
                        -- Also, strongly prefer sending troops toward homeworlds in this case
                        local goal_planet = wesnoth.units.find_on_map { id = goal_id }[1]
                        rating = dist_rating
                        if (goal_planet.variables.colonised == 'homeworld') then
                            rating = rating / 100
                        else
                            rating = rating / 1000
                        end

                        -- We also need to apply a large penalty, otherwise this might be chosen over the options above
                        rating = rating - 100

                        --std_print('----- rating: ', transport_id, goal_id, rating)
                    end

                    if rating and (rating > max_rating) then
                        max_rating = rating
                        best_id = transport_id
                        best_goal_id = goal_id
                        if (pickup_id == 'self') then
                            best_pickup_id = nil
                        else
                            best_pickup_id = pickup_id
                        end
                    end
                end
            end
        end
        --std_print('***** best: ', best_id, best_pickup_id, best_goal_id, max_rating, '\n')

        if best_id then
            set_assignment(assignments, instructions, best_id, best_goal_id, best_pickup_id)

            -- Remove the transport from the ratings table as well as the
            -- pickup planet, if there are no available units left on it
            dist_ratings[best_id] = nil
            if best_pickup_id and (not instructions.available_power[best_pickup_id]) then
                for transport_id,transport_ratings in pairs(dist_ratings) do
                    transport_ratings[best_pickup_id] = nil
                    if (not next(transport_ratings)) then
                        dist_ratings[transport_id] = nil
                   end
                end
            end

            instructions.n_assigned = instructions.n_assigned + 1
        else
            break
        end

        -- If 'stop_when_enough_power' directive is given, stop assigning transports
        -- when enough power has been assigned to each planet.
        if instructions.settings.stop_when_enough_power then
            local enough_power = true
            for planet_id,power_needed in pairs(instructions.power_needed) do
                local power_assigned = instructions.power_assigned[planet_id] or 0
                if (power_assigned < power_needed) then
                    enough_power = false
                    break
                end
            end
            if enough_power then
                break
            end
        end
    end
end


local assignments
local ca_GE_transport_troops = {}

function ca_GE_transport_troops:evaluation(cfg, data)
    local ca_score = CFG.get_cfg_parm('CA_scores')[ca_name]
    if (ca_score < 0) or data.GEAI_abort then return 0 end

    local start_time = wesnoth.ms_since_init() / 1000.
    DBG.print_debug_eval(ca_name, 0, start_time, 'begin eval')


    assignments = {}
    local instructions = {}

    --- Transports ---
    local all_transports = UTLS.get_transports { side = wesnoth.current.side }
    --std_print('#all_transports', #all_transports)

    if (not all_transports[1]) then
        DBG.print_debug_eval(ca_name, 0, start_time, 'no transports found')
        return 0
    end

    -- Find assigned and unassigned transports
    -- Some assigned transports might not have valid goals any more, but
    -- that is purpose dependent and therefore checked later
    local assigned_transports, unassigned_transports = {}, {}
    for _,transport in pairs(all_transports) do
        local purpose = transport.variables.GEAI_purpose
        if purpose then
            local goal_id = transport.variables.GEAI_goal_id
            if (not assigned_transports[purpose]) then assigned_transports[purpose] = {} end
            table.insert(assigned_transports[purpose], transport)
        else
            table.insert(unassigned_transports, transport)
        end
    end
    --for purpose,transports in pairs(assigned_transports) do
    --    for _,transport in ipairs(transports) do
    --        std_print(purpose, 'assigned transport: ' .. UTLS.unit_str(transport) .. ' -> ' .. transport.variables.GEAI_goal_id)
    --    end
    --end
    --for _,transport in ipairs(unassigned_transports) do std_print('unassigned transport: ' .. UTLS.unit_str(transport)) end


    --- Planets ---
    local all_planets = UTLS.get_planets()
    local neutral_planets, enemy_planets, planets_by_id = {}, {}, {}
    local homeworld
    local n_sides = 0 -- number of sides which own a planet
    for _,planet in ipairs(all_planets) do
        if planet:matches {
            { 'filter_side', {  -- this excludes neutral planets
                { 'not', { { 'has_unit', { canrecruit = 'yes' } } } }
            } }
        }
        then
            table.insert(neutral_planets, planet)
        elseif wesnoth.sides.is_enemy(planet.side, wesnoth.current.side) then
            table.insert(enemy_planets, planet)
        end
        if (planet.variables.colonised == 'homeworld') then
            if (planet.side == wesnoth.current.side) then homeworld = planet end
            n_sides = n_sides + 1
        end
        planets_by_id[planet.id] = planet
    end
    --std_print('#neutral_planets', #neutral_planets)
    --std_print('#enemy_planets', #enemy_planets)
    --std_print('n_sides', n_sides)


    -- Find hostile aliens on neutral planets
    local alien_power_by_planet = {}
    local aliens = wesnoth.units.find_on_map { race = 'alien', { 'not', { ability = 'friendly' } } }
    for _,alien in ipairs(aliens) do
        local planet = UTLS.get_planet_from_unit(alien)
        if planet:matches {
                { 'filter_side', {  -- this selects neutral planets
                    { 'not', { { 'has_unit', { canrecruit = 'yes' } } } }
                } }
            }
        then
            local power = UTLS.unit_power(alien)
            --std_print('alien: ' .. UTLS.unit_str(alien), power, planet.id)
            alien_power_by_planet[planet.id] = (alien_power_by_planet[planet.id] or 0) + power
        end
    end

    local max_alien_power = 0
    for _,power in pairs(alien_power_by_planet) do
        if (power > max_alien_power) then
            max_alien_power = power
        end
    end
    --std_print('max_alien_power: ' .. max_alien_power)
    --DBG.dbms(alien_power_by_planet, false, 'alien_power_by_planet')


    -- Check whether an invasion of the AI homeworld is imminent
    -- Consider transports within 2 moves of the homeworld
    local enemy_transports = AH.get_attackable_enemies { ability = 'transport' }
    --std_print('#enemy_transports: ' .. #enemy_transports)

    local homeworld_threats_power = 0
    for _,enemy_transport in ipairs(enemy_transports) do
        local dist = wesnoth.map.distance_between(enemy_transport.x, enemy_transport.y, homeworld.x, homeworld.y)
        --std_print(UTLS.unit_str(enemy_transport), dist)

        -- Don't do path finding if the transport can definitely not get there
        if (dist - 1 <= enemy_transport.max_moves * 2) then
            for xa,ya in H.adjacent_tiles(homeworld.x, homeworld.y) do
                -- ignore units, as some defenders may be killed by enemy ships
                local _,cost = wesnoth.paths.find_path(enemy_transport, xa, ya, { ignore_units = true })
                --std_print('  ' .. UTLS.loc_str({ xa, ya }), cost)

                -- If the transport can get to the homeworld in 2 moves, find the power of its passengers
                -- Note that onboard healing is not taken into account here, but this is close enough
                if (cost <= enemy_transport.max_moves * 2) then
                    local passengers = wml.array_access.get('passengers', enemy_transport)
                    for _,passenger in ipairs(passengers) do
                        local enemy = wesnoth.units.find_on_recall { id = passenger.id }[1]
                        local power = UTLS.unit_power(enemy)
                        --std_print('    ' .. UTLS.unit_str(enemy), power)
                        homeworld_threats_power = homeworld_threats_power + power
                    end

                    -- we're only interested in whether the transport can get there, not in which one is the closest hex
                    -- also needed so that units are not double-counted
                    break
                end
            end
        end
    end
    --std_print('homeworld_threats_power: ' .. homeworld_threats_power)


    --- Troops ---
    local all_units = wesnoth.units.find_on_map()

    instructions.available_units, instructions.available_power = {}, {}
    -- All units currently on transports are available
    for _,transport in pairs(all_transports) do
        local passengers = wml.array_access.get('passengers', transport)

        --DBG.dbms(passengers, false, 'passengers')
        for _,passenger in ipairs(passengers) do
            local unit = wesnoth.units.find_on_recall { id = passenger.id }[1]
            if unit then
                add_available_unit(instructions.available_units, transport.id, unit)
            else
                -- just a safeguard, this should never happen
                error('!!!!!!!!!!!!!!!! ' .. passenger.id .. ' ' .. ' not on ' .. transport.id .. ' on side ' .. wesnoth.current.side)
            end
        end
    end
    --DBG.dbms(instructions, false, 'instructions')

    -- Find all available units on planets,
    -- As well as the power of both own and enemy units on all planets
    local empire = wml.variables['empire[' .. wesnoth.current.side .. ']']
    local faction = empire.faction
    local transport_healing = 2
    if (faction == 'Terran') then
        transport_healing = 6
    end
    --std_print('transport_healing: ' .. transport_healing)

    local planet_powers = {}
    for _,planet in ipairs(all_planets) do
        local my_power, enemy_power = 0, 0
        local my_units_this_planet = {}
        for _,unit in ipairs(all_units) do
            if (unit.role == planet.id) then
-- xxxx this can be simplified
                if unit.race ~= 'building' then
                    if wesnoth.sides.is_enemy(unit.side, wesnoth.current.side) then
                        enemy_power = enemy_power + UTLS.unit_power(unit)
                    elseif (unit.side == wesnoth.current.side) then
                        my_power = my_power + UTLS.unit_power(unit)
                        table.insert(my_units_this_planet, unit)
                    end
                else
                    -- Count enemy HQ at half its HP; don't count our own HQs
                    if wesnoth.sides.is_enemy(unit.side, wesnoth.current.side) then
                        enemy_power = enemy_power + unit.hitpoints / 2
                    end
                end
            end
        end
        planet_powers[planet.id] = { enemy = enemy_power, own = my_power }
        --std_print(planet.id .. ': my vs. enemy power: ' .. my_power .. ' <--> ' .. enemy_power)
        --DBG.dbms(my_units_this_planet, false, 'my_units_this_planet')


        -- Also add the external (units on transports) threats
        if (planet.id == homeworld.id) then
            planet_powers[planet.id].threats = homeworld_threats_power
            -- And this done is so that no units are marked as available below if the AI homeworld is threatened
            enemy_power = enemy_power + homeworld_threats_power
        end

        -- Available units on planets:
        --  - if there are enemies on the planet, we do not move any of ours away
        --  - available units must not be poisoned or not too injured
        --  - in addition, we keep a certain number of units on the homeworld
        if (enemy_power == 0) and (#my_units_this_planet > 0) then
            local keep_units = {}
            if (planet.id == homeworld.id) then
                --std_print('is homeworld: ' .. planet.id, #my_units_this_planet, #neutral_planets)
                -- Allow units for colonising (note that this is intentionally
                -- larger than what is actually assigned below)
                local min_units_available = #neutral_planets / 3
                local n_keep_units = math.floor(math.min(#my_units_this_planet - min_units_available, 8))
                if (n_keep_units < 0) then n_keep_units = 0 end

                -- We want to keep a 2:1 ratio for workers:fighters
                -- If we do not have enough workers or fighters left, only keep as many as we have.
                -- They will be produced and then kept later
                local n_workers =  math.floor(2 / 3 * n_keep_units + 0.5)
                local n_fighters = math.floor(1 / 3 * n_keep_units + 0.5)
                --std_print('keep workers, fighters, total: ', n_workers, n_fighters, n_keep_units)

                local workers, fighters = {}, {}
                for i_u,unit in pairs(my_units_this_planet) do
                    if unit:matches { ability = 'work' } then
                        table.insert(workers, { id = unit.id, power = UTLS.unit_power(unit) })
                    elseif unit:matches { ability = 'science' } then
                    else
                        table.insert(fighters, { id = unit.id, power = UTLS.unit_power(unit) })
                    end
                end
                -- For this purpose, we want to keep the strongest units on the planet
                table.sort(workers, function(a, b) return a.power > b.power end)
                table.sort(fighters, function(a, b) return a.power > b.power end)
                --DBG.dbms(workers, false, 'workers')
                --DBG.dbms(fighters, false, 'fighters')

                for i_u = 1,math.min(#workers, n_workers) do
                    keep_units[workers[i_u].id] = true
                end
                -- Don't hold back fighters if there are hostile aliens on uncolonised planets
                if (max_alien_power == 0) then
                    for i_u = 1,math.min(#fighters, n_fighters) do
                        keep_units[fighters[i_u].id] = true
                    end
                end
            end
            --DBG.dbms(keep_units, false, 'keep_units')
            for _,unit in pairs(my_units_this_planet) do
                if (not keep_units[unit.id])
                    and (not unit.status.poisoned)
                    and (unit.hitpoints >= unit.max_hitpoints - 2 * transport_healing)
                then
                    add_available_unit(instructions.available_units, planet.id, unit)
                end
            end
        end
    end
    --DBG.dbms(instructions.available_units, false, 'instructions.available_units')
    --DBG.dbms(planet_powers, false, 'planet_powers')

    -- Also calculate the total number and combined power of available units on each planet
    local n_available_units = 0
    for id,units in pairs(instructions.available_units) do
        for _,unit_info in pairs(units) do
            n_available_units = n_available_units + 1
            instructions.available_power[id] = (instructions.available_power[id] or 0) + unit_info.power
        end
    end
    --std_print('n_available_units: ' .. n_available_units)
    --DBG.dbms(instructions, false, 'instructions')


    ------ Recruit more transports ------
    local n_needed_colonise = math.ceil(#all_planets / n_sides / 3)
    local n_needed_combat = math.ceil(n_available_units / 3)
    if (#neutral_planets / #all_planets > 0.5) then
        n_needed_combat = 0
    end

    local n_needed_overall = math.max(n_needed_colonise, n_needed_combat)
    --std_print('n_needed colonise, combat, overall:', n_needed_colonise, n_needed_combat, n_needed_overall)

    local n_missing = n_needed_overall - #all_transports
    --std_print('transports needed / missing: ' .. n_needed_overall .. ' / ' .. n_missing)

    if (n_missing > 0) then
        --std_print('  need more transports, checking whether we can recruit more; need: ' .. n_missing)

        -- Simply finds the first unit type that has the transport ability as
        -- each faction only has one transport unit type on the recruit list
        local best_recruit
        for _,recruit_id in ipairs(wesnoth.sides[wesnoth.current.side].recruit) do
            --std_print('  possible recruit: ' .. recruit_id)
            local abilities = wml.get_child(wesnoth.unit_types[recruit_id].__cfg, "abilities")
            if abilities then
                for ability in wml.child_range(abilities, 'dummy') do
                    if (ability.id == 'transport') then
                        --std_print('    -- is transport')
                        best_recruit = recruit_id
                        break
                    end
                end
                if best_recruit then break end
            end
        end
        --std_print('best_recruit: ' .. best_recruit)

        local n_recruits = 0
        if (not best_recruit) then
            --std_print('no transport unit type found on recruit list')
        else
            local cost = wesnoth.unit_types[best_recruit].cost
            n_recruits = math.floor(wesnoth.sides[wesnoth.current.side].gold / cost)
            --std_print('can afford ' .. n_recruits .. ' transports')
        end
        n_recruits = math.min(n_recruits, n_missing)

        local ratings = {}
        if (n_recruits > 0) then
            --std_print('  after checking gold: trying to recruit ' .. n_recruits .. ' transports: ' .. best_recruit)

            local recruit_locs = UTLS.get_recruit_locs()
            --DBG.dbms(recruit_locs, false, 'recruit_locs')
            -- For now, we just use the hex closest to any enemy planet as recruit hex
            for _,loc in ipairs(recruit_locs) do
                for _,planet in ipairs(enemy_planets) do
                    local dist = wesnoth.map.distance_between(planet.x, planet.y, loc[1], loc[2])
                    table.insert(ratings, { rating = dist, x = loc[1], y = loc[2], type = best_recruit })
                end
            end
            table.sort(ratings, function(a, b) return a.rating < b.rating end)
            --DBG.dbms(ratings, false, 'ratings')

            n_recruits = math.min(n_recruits, #ratings, #recruit_locs)
        end

        if (n_recruits > 0) then
            --std_print('  after checking hexes: trying to recruit ' .. n_recruits .. ' transports: ' .. best_recruit)

            assignments = { recruit = { } }

            i = 0
            while (#assignments.recruit < n_recruits) and (i < #ratings) do
                i = i + 1
                -- The ratings table usually contains each recruit hex several times.
                -- Need to make sure we don't assign it multiple times.
                local hex_available = true
                for _,assignment in ipairs(assignments.recruit) do
                    if (ratings[i].x == assignment.x) and (ratings[i].y == assignment.y) then
                        hex_available = false
                        break
                    end
                end
                if hex_available then
                    table.insert(assignments.recruit, ratings[i])
                end
            end
            --DBG.dbms(assignments, false, 'assignments')

            DBG.print_debug_eval(ca_name, ca_score, start_time, #assignments.recruit .. ' transports to be recruited')
            return ca_score
        end

    end
    ------ End recruiting ------


    ------ Defend the AI homeworld ------
    -- If we urgently need power at the homeworld, everything else is second priority
    local homeworld_power_own = planet_powers[homeworld.id].own
    local homeworld_power_enemy = planet_powers[homeworld.id].enemy + planet_powers[homeworld.id].threats
    local homeworld_power_needed = 1.5 * homeworld_power_enemy - homeworld_power_own
    --std_print('Homeworld own power:             ' .. homeworld_power_own)
    --std_print('Homeworld enemy power + threats: ' .. homeworld_power_enemy)
    --std_print('Homeworld power needed:          ' .. homeworld_power_needed)

    if (homeworld_power_needed > 0) then
        instructions.settings = {
            purpose = 'defend_homeworld',
            n_needed = math.huge, -- for defending the homeworld, we always assign as many transports as needed
            stop_when_enough_power = true,
            enough_power_only = false
        }

        instructions.power_needed = {}
        instructions.power_needed[homeworld.id] = homeworld_power_needed
        instructions.n_assigned = 0

        add_combat_rating(instructions.available_units)

        -- First we check whether the already assigned transports provide enough power
        for _,transport in ipairs(assigned_transports.defend_homeworld or {}) do
            local goal_id = transport.variables.GEAI_goal_id
            local pickup_id = transport.variables.GEAI_pickup_id
            if (goal_id == homeworld.id)
                and ((not pickup_id) or instructions.available_units[pickup_id])
            then
                set_assignment(assignments, instructions, transport.id, goal_id, pickup_id)
            end
        end
        --DBG.dbms(assignments, false, 'assignments defend_homeworld existing')
        --DBG.dbms(instructions, false, 'instructions')

        homeworld_power_assigned = instructions.power_assigned and instructions.power_assigned[homeworld.id] or 0
        homeworld_power_missing = homeworld_power_needed - homeworld_power_assigned
        --std_print('Homeworld power assigned:        ' .. homeworld_power_assigned)
        --std_print('Homeworld power missing:         ' .. homeworld_power_missing)

        if (homeworld_power_missing > 0) then
            -- If there is power missing at the homeworld, we unassigned all other transports
            -- and assign transports to defending the homeworld as the highest priority
            -- In fact, given that things might have changed, we also erase previous assignments
            -- for defending the homeworld in order to find the optimum solution for the current situation

            for purpose,transports in pairs(assigned_transports) do
                for _,transport in ipairs(transports) do
                    --std_print(purpose, 'assigned transport: ' .. UTLS.unit_str(transport) .. ' -> ' .. transport.variables.GEAI_goal_id)
                    table.insert(unassigned_transports, transport)
                end
            end
            assigned_transports = {}
            assignments = {}

            find_assignments(assignments, unassigned_transports, instructions, planets_by_id)
        end
    end
    --DBG.dbms(assignments, false, 'assignments defend_homeworld')
    --DBG.dbms(instructions, false, 'instructions defend_homeworld')

    if (assignments.defend_homeworld) and (assignments.defend_homeworld[1]) then
        DBG.print_debug_eval(ca_name, ca_score, start_time, #assignments.defend_homeworld .. ' transports found for defending the homeworld')
        return ca_score
    end


    ------ Colonise neutral planets ------

    -- Colonising is slightly different from the other purposes in that we want to go to several
    -- planets with the same transport/troops. This is easy when there are no aliens, but if there
    -- are, some planets will have aliens, while others don't. Thus, we want to load the transport
    -- with enough power for planets with aliens, but not disable an assignment if it provides
    -- enough power for the currently considered transport. As a result, we use both a
    -- "desired" and a "needed" power setting for colonising.

    --std_print('colonise: number of neutral planets: ' .. #neutral_planets)
    if (#neutral_planets > 0) then
        instructions.settings = {
            purpose = 'colonise',
            n_needed = n_needed_colonise,
            power_desired = math.max(max_alien_power * 1.2, 1),
            stop_when_enough_power = true,
            enough_power_only = true -- ignore planets that have so many aliens that we cannot take them
        }
        --DBG.dbms(instructions.settings, false, 'instructions.settings colonise')

        instructions.power_needed = {}
        instructions.n_assigned = 0

        -- For colonising, we just need any unit, except when there are aliens
        -- Note that this is only the power of aliens, not counting alien HQs or other
        -- enemy units on the same planet. As this is for colonising, this is generally
        -- okay, as most planets will only be neutral early in the game. Later in the game,
        -- the next purpose (combat) might send more troops to the same planet if there
        -- are other enemy units on it.
        for _,planet in ipairs(neutral_planets) do
            -- note the 'or 1' (as opposed to 'or 0'), otherwise planets without aliens will not be colonised
            instructions.power_needed[planet.id] = (alien_power_by_planet[planet.id] or 1) * 1.2
        end
        --DBG.dbms(instructions.power_needed, false, 'power_needed colonise')

        local artifact_locs = UTLS.get_artifact_locs()
        --std_print('#artifact_locs: ' .. #artifact_locs)
        -- Add colonising bonus by population type
        for _,unit_infos in pairs(instructions.available_units) do
            for _,unit_info in pairs(unit_infos) do
                local rating = 1 + unit_info.power / 1000

                -- Since transports heal, and injured units cannot work or do science,
                -- prefer injured units. Note that unit power is reduced when they are
                -- injured, so this contribution needs to be stronger than that
                rating = rating + unit_info.hp_missing / 100
                if (faction == 'Iildari') then
                    if (unit_info.type == 'combat_unit') then
                        rating = rating * 1.2
                    elseif (unit_info.type == 'science_unit') then
                        rating = rating * 1.1
                    end
                else
                    if (unit_info.type == 'combat_unit') then
                        rating = rating * 1.2
                    elseif (unit_info.type == 'work_unit') then
                        rating = rating * 1.1
                    end
                end

                -- Bonus for scientists if there are artifacts
                if (#artifact_locs > 0) then
                    if (unit_info.type == 'science_unit') then
                        rating = rating * 1.3
                    end
                end

                -- Bonus for fighters if there are non-friendly aliens
                if (#aliens > 0) then
                    if (unit_info.type == 'combat_unit') then
                        rating = rating * 1.5
                    end
                end

                unit_info.rating = rating
            end
        end
        --DBG.dbms(instructions, false, 'instructions')
        --DBG.dbms(instructions.available_units, false, 'instructions.available_units')

        -- First, set the assignments for already-assigned transports
        -- Unassign those whose goal is not valid any more:
        --  - goal planet has been colonised in the meantime
        --  - no units available any more on pickup planet
        for _,transport in ipairs(assigned_transports.colonise or {}) do
            local goal_id = transport.variables.GEAI_goal_id
            local pickup_id = transport.variables.GEAI_pickup_id
            if planets_by_id[goal_id]:matches {
                    { 'filter_side', {  -- this excludes neutral planets
                        { 'not', { { 'has_unit', { canrecruit = 'yes' } } } }
                    } }
                }
                and ((not pickup_id) or instructions.available_units[pickup_id])
            then
                --std_print('set assignment: ' .. UTLS.unit_str(transport))
                set_assignment(assignments, instructions, transport.id, goal_id, pickup_id)
                --DBG.dbms(assignments, false, 'assignments colonise')
                --DBG.dbms(instructions.power_assigned, false, 'instructions.power_assigned')
            else
                --std_print('unset assignment: ' .. UTLS.unit_str(transport))
                -- We do not need to remove the transport from the assigned_transports table
                -- We do, however, need to add it to the unassigned_transports table
                -- Also, we cannot delete its variables, as that would cause OOS errors; this
                -- is done by the execution function if a new purpose for the transport is found
                table.insert(unassigned_transports, transport)
            end
        end

        -- Then, find new ones
        find_assignments(assignments, unassigned_transports, instructions, planets_by_id)
    end
    --DBG.dbms(assignments, false, 'assignments colonise')
    --DBG.dbms(instructions.power_assigned, false, 'instructions.power_assigned')

    if (assignments.colonise) and (assignments.colonise[1]) then
        DBG.print_debug_eval(ca_name, ca_score, start_time, #assignments.colonise .. ' transports found for colonising')
        return ca_score
    end
    ------ End colonise planets ------


    ------ Move combat units ------
    instructions.settings = {
        purpose = 'combat',
        n_needed = math.huge, -- for combat, we always assign all transports
        stop_when_enough_power = false,
        enough_power_only = false
    }

    instructions.power_needed = {}
    instructions.n_assigned = 0

    add_combat_rating(instructions.available_units)

    --DBG.dbms(planet_powers, false, 'planet_powers')
    for planet_id,powers in pairs(planet_powers) do
        local planet = planets_by_id[planet_id]
        local rating
        if (powers.enemy > 0) then
            -- Note that this rating is negative. Also note that this is only used as a flag at the moment
            rating = powers.own - powers.enemy
        end
        local str = '  rating: ' .. (rating or 'nil')

        local power_needed = 0
        if (planet.side == wesnoth.current.side) then
            if (powers.enemy > 0) then
                -- Use somewhat higher power_needed to defend own planet ...
                power_needed = 1.5 * powers.enemy - powers.own
                str = str .. '  need to defend'
            end
        else
            -- ... than to attack an enemy planet; but both are larger than the actual power difference
            power_needed = 1.2 * powers.enemy - powers.own
            str = str .. '  consider attacking'
        end

        if rating then
            --std_print(UTLS.unit_str(planet), str)
            if (power_needed > 0) then
                instructions.power_needed[planet_id] = power_needed
            end
        end
    end
    --DBG.dbms(instructions, false, 'instructions')

    -- First, set the assignments for already-assigned transports
    -- Unassign those whose goal is not valid any more:
    --  - goal planet does not need power any more
    --  - no units available any more on pickup planet
    for _,transport in ipairs(assigned_transports.combat or {}) do
        local goal_id = transport.variables.GEAI_goal_id
        local pickup_id = transport.variables.GEAI_pickup_id
        if (instructions.power_needed[goal_id])
            and ((not pickup_id) or instructions.available_units[pickup_id])
        then
            set_assignment(assignments, instructions, transport.id, goal_id, pickup_id)
        else
            -- We do not need to remove the transport from the assigned_transports table
            -- We do, however, need to add it to the unassigned_transports table
            -- Also, we cannot delete its variables, as that would cause OOS errors; this
            -- is done by the execution function if a new purpose for the transport is found
            table.insert(unassigned_transports, transport)
        end
    end
    --DBG.dbms(assignments, false, 'assignments combat')
    --DBG.dbms(instructions.power_needed, false, 'instructions.power_needed')
    --DBG.dbms(instructions.power_assigned, false, 'instructions.power_assigned')
    --DBG.dbms(instructions, false, 'instructions')
    --for _,transport in ipairs(unassigned_transports) do std_print('unassigned transport: ' .. UTLS.unit_str(transport)) end

    -- Then, find new ones
    find_assignments(assignments, unassigned_transports, instructions, planets_by_id)
    --DBG.dbms(assignments, false, 'assignments combat')

    if (not assignments.combat) or (not assignments.combat[1]) then
        DBG.print_debug_eval(ca_name, 0, start_time, 'no qualifying transport moves found')
        return 0
    end

    DBG.print_debug_eval(ca_name, ca_score, start_time, #assignments.combat .. ' transports found for combat troops')
    return ca_score
    ------ End move combat units ------
end


function ca_GE_transport_troops:execution(cfg, data, ai_debug)
    local ai = ai or ai_debug

    --DBG.dbms(assignments, false, 'assignments execution')

    ------ Recruiting ------
    if assignments.recruit then
        for _,assignment in ipairs(assignments.recruit) do
            local str = 'recruit ' .. assignment.type .. ' at ' .. UTLS.loc_str(assignment)
            DBG.print_debug_exec(ca_name, str)
            UTLS.output_add_move(str)

            AH.checked_recruit(ai, assignment.type, assignment.x, assignment.y)
        end

        -- We stop at this point and reevaluate
        assignments = {}
        return
    end


    ------ Moving troops ------
    for purpose,purpose_assignments in pairs(assignments) do
        for _,assignment in ipairs(purpose_assignments) do
            --DBG.dbms(assignment, false, 'assignment')

            local transport = wesnoth.units.find_on_map { id = assignment.transport_id }[1]
            local goal_planet = wesnoth.units.find_on_map { id = assignment.goal_id }[1]
            local pickup_planet
            if assignment.pickup_id then
                pickup_planet = wesnoth.units.find_on_map { id = assignment.pickup_id }[1]
            end
            --std_print(UTLS.unit_str(transport) .. ' --> ' .. UTLS.unit_str(goal_planet) .. ', unit pickup: ' .. (UTLS.unit_str(pickup_planet, 'none')))


            --- Set the unit variables
            if (not are_variables_set(transport, purpose, assignment.goal_id, assignment.pickup_id)) then
                local str = 'set transport goal: ' .. purpose .. ': ' .. UTLS.unit_str(transport) .. ' --> ' .. UTLS.unit_str(goal_planet)
                if pickup_planet then
                    str = str .. ' via ' .. UTLS.unit_str(pickup_planet)
                end
                DBG.print_debug_exec(ca_name, str)
                UTLS.output_add_move(str)

                wesnoth.sync.invoke_command('GEAI_set_unit_variable', { id = transport.id, name = 'GEAI_purpose', value = purpose })
                wesnoth.sync.invoke_command('GEAI_set_unit_variable', { id = transport.id, name = 'GEAI_goal_id', value = assignment.goal_id })
                wesnoth.sync.invoke_command('GEAI_set_unit_variable', { id = transport.id, name = 'GEAI_pickup_id', value = assignment.pickup_id })

                if (not are_variables_set(transport, purpose, assignment.goal_id, assignment.pickup_id)) then
                    data.GEAI_abort = true
                    error('Assigning variables to transport ' .. transport.id .. ' did not succeed')
                else
                    UTLS.force_gamestate_change(ai)
                end
            end


            --- Move toward pickup planet if:
            --   - pickup planet is set
            --   - transport has moves left
            --   - transport is not already adjacent to pickup planet
            if pickup_planet
                and (transport.moves > 0)
                and (wesnoth.map.distance_between(pickup_planet.x, pickup_planet.y, transport.x, transport.y) ~= 1)
            then
                local min_rating, best_hex = math.huge, {}
                for xa,ya in H.adjacent_tiles(pickup_planet.x, pickup_planet.y) do
                    local _,cost = wesnoth.paths.find_path(transport, xa, ya)
                    local dist_goal = wesnoth.map.distance_between(xa, ya, goal_planet.x, goal_planet.y)
                    cost = cost + dist_goal / 100

                    -- if there's a unit on it, significantly increase the cost
                    if wesnoth.units.get(xa, ya) then
                        cost = cost + transport.max_moves
                    end
                    --std_print(UTLS.unit_str(transport) .. ' --> ' .. UTLS.unit_str(pickup_planet), UTLS.loc_str(xa, ya), cost)

                    if (cost < min_rating) then
                        min_rating = cost
                        best_hex = { xa, ya }
                    end
                end
                local next_hop = AH.next_hop(transport, best_hex[1], best_hex[2])

                local str = 'move ' .. UTLS.unit_str(transport) .. ' toward ' .. UTLS.unit_str(pickup_planet) .. ' for pickup --> ' .. UTLS.loc_str(next_hop)
                DBG.print_debug_exec(ca_name, str)
                UTLS.output_add_move(str)
                AH.robust_move_and_attack(ai, transport, next_hop, nil, { partial_move = true })
            end


            --- Beam up units if:
            --   - pickup planet is set
            --   - transport has moves left
            --   - transport is adjacent to pickup planet
            if pickup_planet
                and (transport.moves > 0)
                and (wesnoth.map.distance_between(pickup_planet.x, pickup_planet.y, transport.x, transport.y) == 1)
            then
                local direction = wesnoth.map.get_relative_dir({ transport.x, transport.y } , { pickup_planet.x, pickup_planet.y })

                for _,unit_id in ipairs(assignment.assigned_unit_ids) do
                    local unit = wesnoth.units.find_on_map { id = unit_id }[1]

                    -- Units already on the transport are also on the assignment list, so
                    -- those are not found on the planet surface
                    if unit then
                        local beam_up_cfg = { x = unit.x, y = unit.y, direction = direction }

                        local str = 'beam up ' .. UTLS.unit_str(unit) .. ' from ' .. UTLS.unit_str(pickup_planet) .. ' to ' .. UTLS.unit_str(transport)
                        DBG.print_debug_exec(ca_name, str)
                        UTLS.output_add_move(str)

                        -- Check that beaming is successful, to prevent infinite loops if something goes wrong
                        local passengers_before = transport.attacks[1].damage

                        wesnoth.sync.invoke_command('GEAI_beam_up', beam_up_cfg)

                        local passengers_after = transport.attacks[1].damage
                        --std_print('passengers before, after:', passengers_before, passengers_after)
                        if (passengers_after ~= passengers_before + 1) then
                            data.GEAI_abort = true
                            error('beam-up CA: something went wrong with: ' .. str)
                        else
                            UTLS.force_gamestate_change(ai)
                        end
                    end
                end

                -- Need to delete the pickup planet from the assignment
                wesnoth.sync.invoke_command('GEAI_set_unit_variable', { id = transport.id, name = 'GEAI_pickup_id' })
                pickup_planet = nil
            end


            --- Move toward goal planet if:
            --   - pickup planet is not set
            --   - transport has moves left
            --   - do NOT check if transport is already adjacent to goal planet; if it is, this means
            --     that it was either just assigned (because something changed) or that it cannot
            --     beam down its passengers (because the beam-down hex is occupied)
            if (not pickup_planet) and (transport.moves > 0) then
                local min_rating, best_hex = math.huge, {}

                -- If there are artifact or aliens on the planet, try to beam down close to them
                local artifact_locs = UTLS.get_artifact_locs {
                    x = goal_planet.variables.hq_x,
                    y = goal_planet.variables.hq_y,
                    radius = goal_planet.variables.radius
                }
                --std_print('#artifact_locs: ' .. #artifact_locs)

                local aliens = wesnoth.units.find_on_map { race = 'alien', role = goal_planet.id }
                --std_print('#aliens: ' .. #aliens)

                for xa,ya in H.adjacent_tiles(goal_planet.x, goal_planet.y) do
                    local _,cost = wesnoth.paths.find_path(transport, xa, ya)
                    local can_reach = (cost <= transport.moves)
                    --std_print(xa,ya,can_reach)

                    -- if there's a unit on it, significantly increase the cost
                    if wesnoth.units.get(xa, ya) then
                        cost = cost + transport.max_moves
                    end
                    --std_print(UTLS.unit_str(transport) .. ' --> ' .. UTLS.unit_str(goal_planet), UTLS.loc_str(xa, ya), cost)

                    local penalty = 0
                    local beam_loc, unit_in_way, direction = get_beam_down_loc(goal_planet, { x = xa, y = ya })
                    if unit_in_way then
                        if wesnoth.sides.is_enemy(unit_in_way.side, wesnoth.current.side)
                            and (not unit_in_way:matches { ability = 'friendly' })
                        then
                            -- Go up to one full move out of the way to beam down on an enemy
                            penalty = penalty - 5
                        elseif (unit_in_way.side == wesnoth.current.side) then
                            local reachmap = AH.get_reachmap(unit_in_way, { exclude_occupied = true })
                            if (reachmap:size() <= 1) then
                                -- Huge penalty if own unit cannot move out of the way
                                penalty = penalty + 99
                            else -- small incentive to move own units out of the way
                                penalty = penalty + 1 / reachmap:size()
                            end
                        else -- Huge penalty if there is an allied unit
                            penalty = penalty + 99
                        end
                    end
                    --std_print(UTLS.loc_str(xa, ya), direction, UTLS.loc_str(beam_loc), penalty)
                    cost = cost + penalty

                    -- The following are only applied to hexes the transport can reach
                    -- As such, they only work if they are boni, but they still need to be
                    -- in units of moves; we do that by simply adding an arbitrary large bonus
                    -- (negative cost) which applies equally to all hexes that can be reached
                    if can_reach then
                        -- Try to get close to artifact
                        for _,artifact_loc in ipairs(artifact_locs) do
                            local dist = wesnoth.map.distance_between(beam_loc[1], beam_loc[2], artifact_loc[1], artifact_loc[2])
                            -- Transport may go a bit more than a move farther for each move saved on the surface
                            cost = cost + 1.5 * dist - 10
                        end

                        -- Same for aliens, with a slightly smaller contribution
                        for _,alien in ipairs(aliens) do
                            local dist = wesnoth.map.distance_between(beam_loc[1], beam_loc[2], alien.x, alien.y)
                            -- Transport may go a bit more than a move farther for each move saved on the surface
                            cost = cost + 1.4 * dist - 10
                        end
                    end

                    if (cost < min_rating) then
                        min_rating = cost
                        best_hex = { xa, ya }
                    end
                end
                local next_hop = AH.next_hop(transport, best_hex[1], best_hex[2])

                local str = 'move ' .. UTLS.unit_str(transport) .. ' toward ' .. UTLS.unit_str(goal_planet) .. ' --> ' .. UTLS.loc_str(next_hop)
                DBG.print_debug_exec(ca_name, str)
                UTLS.output_add_move(str)
                AH.robust_move_and_attack(ai, transport, next_hop, nil, { partial_move = true })
            end


            --- Beam down a unit if:
            --   - pickup planet is not set (because transport might end up next
            --     to goal planet by coincidence on way to pickup planet)
            --   - transport is adjacent to goal planet
            -- Also move units on the beam-down hex out of the way
            if (not pickup_planet)
                and (wesnoth.map.distance_between(goal_planet.x, goal_planet.y, transport.x, transport.y) == 1)
            then
                for _,unit_id in ipairs(assignment.assigned_unit_ids) do
                    local passengers = wml.array_access.get('passengers', transport)
                    local passenger_index
                    for i_p,passenger in pairs(passengers) do
                        if (passenger.id == unit_id) then
                            passenger_index = i_p
                            break
                        end
                    end

                    if (not passenger_index) then -- this should not happen; only here for trouble shooting
                        DBG.dbms(passengers, false, 'passengers beam-down error')
                        std_print(UTLS.unit_str(transport))
                        DBG.dbms(assignment, false, 'passengers beam-down error')
                    end

                    -- If there's a unit in the beam-down location, try to move it out of the way
                    local beam_loc, unit_in_way = get_beam_down_loc(goal_planet, transport)
                    if unit_in_way and (unit_in_way.side == wesnoth.current.side) then
                        AH.move_unit_out_of_way(ai, unit_in_way)
                    end

                    -- Check whether the hex is now available
                    -- Since we are not moving the transport in between beaming, we can simply break the loop
                    local unit_in_way = wesnoth.units.get(beam_loc[1], beam_loc[2])
                    if unit_in_way
                        and ((not wesnoth.sides.is_enemy(unit_in_way.side, wesnoth.current.side))
                        or unit_in_way:matches { ability = 'friendly' })
                    then
                        break
                    end

                    local beam_down_cfg = {
                        id = unit_id,
                        index = passenger_index,
                        transport_id = transport.id,
                        planet_id = goal_planet.id
                    }

                    local str = 'beam down ' .. beam_down_cfg.id .. ' on ' .. UTLS.unit_str(transport) .. ' to ' .. UTLS.unit_str(goal_planet)
                    DBG.print_debug_exec(ca_name, str)
                    UTLS.output_add_move(str)

                    -- Check that beaming is successful, to prevent infinite loops if something goes wrong
                    local passengers_before = transport.attacks[1].damage

                    wesnoth.sync.invoke_command('GEAI_beam_down', beam_down_cfg)

                    local passengers_after = transport.attacks[1].damage
                    --std_print('passengers before, after:', passengers_before, passengers_after)
                    if (passengers_after ~= passengers_before - 1) then
                        data.GEAI_abort = true
                        error('Something went wrong with ' .. str)
                    else
                        UTLS.force_gamestate_change(ai)
                    end

                    -- If this is for colonising and there are no aliens on the planet,
                    -- we only need to beam down one unit
                    if (purpose == 'colonise') then
                        local aliens = wesnoth.units.find_on_map { race = 'alien', role = goal_planet.id }
                        --std_print('# aliens: ' .. #aliens)
                        if (#aliens == 0) then
                            break
                        end
                    end

                    -- This designates the end of this assignment --> delete all remaining unit variables
                    -- A new assignment will be issued in the next call to transport_troops
                    -- Important: this needs to be inside the unit 'for' loop, because there is a 'break' up there
                    -- that might end the loop without changing the gamestate, resulting in an infinite loop
                    wesnoth.sync.invoke_command('GEAI_set_unit_variable', { id = transport.id, name = 'GEAI_goal_id' })
                    wesnoth.sync.invoke_command('GEAI_set_unit_variable', { id = transport.id, name = 'GEAI_purpose' })
                end
            end
        end
    end

    assignments = {}
end

return ca_GE_transport_troops

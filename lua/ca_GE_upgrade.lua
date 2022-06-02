----- CA: upgrade -----
--
-- Description:
--   Check what upgrades are available for ships, HQs and planets and apply them.
--   This also moves a ship next to a spacedock if it is within one move and an
--   upgrade for it is to be installed

local UPGRD = wesnoth.require('~add-ons/Galactic_Empires/upgrades.lua')

local ca_name = 'upgrade'

local best_upgrade
local ca_GE_upgrade = {}

function ca_GE_upgrade:evaluation(cfg, data)
    local ca_score = CFG.get_cfg_parm('CA_scores')[ca_name]
    local ca_score_flagship = CFG.get_cfg_parm('CA_scores')[ca_name .. '_flagship']
    local ca_score_ship = CFG.get_cfg_parm('CA_scores')[ca_name .. '_ship']
    if (ca_score < 0) or data.GEAI_abort then return 0 end

    local start_time = wesnoth.ms_since_init() / 1000.
    DBG.print_debug_eval(ca_name, 0, start_time, 'begin eval')


    best_upgrade = nil


    ------ Begin debug testing code ------
    -- Set this to 'true' to turn off randomness
    local skip_random = false

    -- For debug testing only, needs to be disabled for playing
    -- Set research levels, so that upgrades are available for testing
    if false then
        --wml.variables['empire[' .. wesnoth.current.side .. '].research_gadgets'] = 3
        wml.variables['empire[' .. wesnoth.current.side .. '].research_hq'] = 3
        --wml.variables['empire[' .. wesnoth.current.side .. '].research_planet'] = 3
        -- The same does not work for research_ships, the recruit list needs to be changed for that
    end

    -- This is for manual debug mode only. In a normal game, these variables are set by the reset_vars CA
    if (not data.turn_start_gold) or (data.turn ~= wesnoth.current.turn) then
        wesnoth.interface.add_chat_message(ca_name .. ' CA', 'setting data.turn_start_gold')
        UTLS.reset_vars(data)
    end

    if false then -- this is just testing code to analyse the production of all the planets on the map
        local all_planets = UTLS.get_planets()
        std_print('total food, gold')
        for _,planet in ipairs(all_planets) do
            local total_food, total_gold = UTLS.total_production(planet)
            std_print(UTLS.unit_str(planet) .. ': ', total_food, total_gold)
        end
    end
    ------ End debug testing code ------


    -- Install upgrades up to certain limits (see GEAI_config.lua for details)
    -- Essential upgrades are installed up to this limit. Only one non-essential
    -- upgrade is installed each turn. This is done by setting data.upgrades_gold
    -- to greater than data.turn_start_gold if a non-essential upgrade is installed.
    local upgrade_gold_fraction = CFG.get_cfg_parm('upgrade_gold_fraction')
    local upgrade_gold_remaining = CFG.get_cfg_parm('upgrade_gold_remaining')
    local upgrade_first_turn = CFG.get_cfg_parm('upgrade_first_turn')
    --std_print('upgrade_gold_fraction: ' .. upgrade_gold_fraction)
    --std_print('upgrade_gold_remaining: ' .. upgrade_gold_remaining)
    --std_print('upgrade_first_turn: ' .. upgrade_first_turn)

    local available_gold = math.min(
       upgrade_gold_fraction * data.turn_start_gold,
       wesnoth.sides[wesnoth.current.side].gold - upgrade_gold_remaining
    )
    --std_print('available_gold:           ' .. available_gold .. '/' .. wesnoth.sides[wesnoth.current.side].gold)

    -- More expensive upgrades are allowed with probability 'upgrade_prob_expensive'.
    -- This must be decided only once per turn -> save in persistent data variable,
    -- which is erased at beginning of each turn by the reset_vars CA.
    if (data.allow_expensive_upgrades == nil) then
        data.allow_expensive_upgrades = math.random() < CFG.get_cfg_parm('upgrade_prob_expensive')
        --std_print('Recalculate data.allow_expensive_upgrades: ', data.allow_expensive_upgrades)
    end

    -- Use separate variable to determine how much gold is available for expensive upgrades.
    -- If no expensive upgrades are allowed, set it to same value as available_gold.
    local available_gold_expensive = available_gold
    if data.allow_expensive_upgrades then
        available_gold_expensive = wesnoth.sides[wesnoth.current.side].gold
    end

    -- With reasonable values of the configuration parameters, the following should
    -- not be needed, but just in case they get set to something strange
    if (available_gold_expensive < available_gold) then available_gold_expensive = available_gold end
    --std_print('available_gold_expensive: ' .. available_gold_expensive)


    -- data.upgrades_gold: gold that has already been spent on upgrades this turn
    if (data.upgrades_gold >= available_gold_expensive) or (wesnoth.current.turn < upgrade_first_turn) then
        DBG.print_debug_eval(ca_name, 0, start_time, 'reached limit of upgrades to be installed this turn')
        return 0
    end


    -- Read all existing upgrades and their costs from the GE WML file
    local upgrade_costs_wml = filesystem.read_file('~add-ons/Galactic_Empires/macros/upgrade_costs.cfg')
    local all_upgrades = {}
    for macro_def in upgrade_costs_wml:gmatch('#define COST_[%a_]+') do
        local full_name = macro_def:sub(14) -- cut off the '#define COST_'

        -- separate into category, update type and cost
        local i_underscore = full_name:find('_')  -- position of first underscore
        local category = string.lower(full_name:sub(1, i_underscore - 1))
        local utype = full_name:sub(i_underscore+1)
        local i = upgrade_costs_wml:find(utype)
        local cost = tonumber(upgrade_costs_wml:match("%d+", i))
        utype = utype:lower()
        --std_print(category, utype, cost)

        if (not all_upgrades[category]) then all_upgrades[category] = {} end
        all_upgrades[category][utype] = cost
    end
    --DBG.dbms(all_upgrades, false, 'all_upgrades')

    -- xxxx This is a work-around for an inconsistency in GE, with the cloner entry still
    -- existing in the upgrades cost file, but the upgrade itself having been removed.
    -- It can be removed after the next GE update.
    all_upgrades.hq.cloner = nil


    ----- Headquarter and planet upgrades -----
    local headquarters = UTLS.get_headquarters { side = wesnoth.current.side }
    --std_print('#headquarters: ' .. #headquarters)


    -- Do these only once per call, otherwise it is pretty much guaranteed that there
    -- will be a value close to the maximum for each of these for one or several upgrades.
    local hq_base_rating = UTLS.random_between(4, 10, skip_random)
    local planet_base_rating = UTLS.random_between(6, 10, skip_random)
    local planet_defensive_upgrade_bonus = UTLS.random_between(2, 4, skip_random)
    local ship_base_rating = UTLS.random_between(2, 10, skip_random)
    local homeworld_factor = UTLS.random_between(1, 2, skip_random)
    local flagship_factor = UTLS.random_between(1, 2, skip_random)

    local max_rating = - math.huge
    for _,hq in ipairs(headquarters) do
        local planet = UTLS.get_planet_from_unit(hq)
        --std_print('HQ: ' .. UTLS.unit_str(hq) .. ' <--> ' .. UTLS.unit_str(planet))

        -- For the filter to work, the headquarter needs to be stored as 'hq' in WML
        -- and the planet in the 'planet' variable
        wml.fire("store_unit", { variable = "hq", { "filter", { id = hq.id } } })
        wml.fire("store_unit", { variable = "planet", { "filter", { id = planet.id } } })

        -- Minor ratings apply equally to HQs and planets
        local minor_rating = 0
        minor_rating = minor_rating + UTLS.random_between(hq.variables.population_current / 20, nil, skip_random)
        minor_rating = minor_rating + UTLS.random_between(hq.variables.population_max / 50, nil, skip_random)

        -- Allow some, but not full random mixing between these
        if (planet.type == 'Green Giant') then minor_rating = minor_rating + UTLS.random_between(0.8, 1, skip_random)
        elseif (planet.type == 'Red Giant') then minor_rating = minor_rating + UTLS.random_between(0.7, 0.95, skip_random)
        elseif (planet.type == 'Green Dwarf') then minor_rating = minor_rating + UTLS.random_between(0.6, 0.9, skip_random)
        elseif (planet.type == 'Dust Giant') then minor_rating = minor_rating + UTLS.random_between(0.5, 0.85, skip_random)
        elseif (planet.type == 'Red Dwarf') then minor_rating = minor_rating + UTLS.random_between(0.4, 0.8, skip_random)
        elseif (planet.type == 'Ice Giant') then minor_rating = minor_rating + UTLS.random_between(0.3, 0.75, skip_random)
        elseif (planet.type == 'Dust Dwarf') then minor_rating = minor_rating + UTLS.random_between(0.2, 0.7, skip_random)
        elseif (planet.type == 'Ice Dwarf') then minor_rating = minor_rating + UTLS.random_between(0.1, 0.65, skip_random)
        elseif (planet.type == 'Moon') or (planet.type == 'Red Moon') then minor_rating = minor_rating + UTLS.random_between(0, 0.6, skip_random)
        else DBG.error('upgrade', 'Unknown planet type: ' .. planet.type)
        end
        --std_print('  minor_rating: ' .. minor_rating)


        ------ Headquarter upgrades ------
        --std_print('  -- HQ upgrades --')
        local total_food, total_gold = UTLS.total_production(planet)
        --std_print('    total food, gold: ' .. total_food, total_gold)

        local enemies = UTLS.get_units_on_planet(planet, {
            { 'filter_side', { { 'enemy_of', {side = wesnoth.current.side } } } }
        })
        --std_print('    #enemies: ' .. #enemies)

        local my_units = UTLS.get_units_on_planet(planet, {
            side = wesnoth.current.side,
            { 'not', { has_weapon = 'food' } } -- exclude the HQ
        })
        --std_print('    #my_units: ' .. #my_units)

        local n_injured, n_work, n_science, n_combat = 0, 0, 0, 0
        for _,unit in ipairs(my_units) do
            if (unit.hitpoints < unit.max_hitpoints) then
                n_injured = n_injured + 1
            end
            if unit:matches { ability = 'work' } then
                n_work = n_work + 1
            elseif unit:matches { ability = 'science' } then
                n_science = n_science + 1
            else
                n_combat = n_combat + 1
            end
        end
        --std_print('    #my_units: ' .. #my_units .. '  (' .. n_injured .. ' injured)')
        --std_print('    #work, #science, #combat: ' .. n_work, n_science, n_combat)

        -- How full is the food store
        local food_store_capacity = hq.attacks[1].damage / hq.attacks[1].number
        --std_print('    food store capacity: ' .. food_store_capacity)

        for hq_upgrade,cost in pairs(all_upgrades.hq) do
            local is_available = UPGRD.show_item(hq_upgrade)

            if is_available and (cost <= available_gold_expensive) then
                local hq_rating = hq_base_rating

                if (hq_upgrade == 'autofix_hq') and (hq.hitpoints < hq.max_hitpoints) then
                    hq_rating = hq_rating + UTLS.random_between(2000 * (1 + #enemies / 10), nil, skip_random)
                end

                if (hq_upgrade == 'hospital') and (n_injured > 0) then
                    hq_rating = hq_rating + UTLS.random_between(1000 * (1 + n_injured / 10) * (1 + #enemies / 10), nil, skip_random)
                end

                if (hq_upgrade == 'barracks')
                    and ((#enemies > 0) or (total_food >= 10))
                then
                    hq_rating = hq_rating + UTLS.random_between(150 + #enemies + total_food / 10, 200, skip_random)
                end

                if (hq_upgrade == 'food_processor') then
                    local bonus = 100 + math.max(0, 50 - total_food)
                    --std_print('food processor bonus: ' .. bonus)
                    hq_rating = hq_rating + UTLS.random_between(bonus, 200, skip_random)
                end

                if (hq_upgrade == 'mineral_processor') then
                    hq_rating = hq_rating + UTLS.random_between(100, 200, skip_random)
                end

                if (#enemies < 2) then
                    if (n_work >= 4) then
                        if (hq_upgrade == 'replicator')
                            and (total_food >= total_gold) and (total_food >= 8)
                        then
                            hq_rating = hq_rating + UTLS.random_between(100, 200, skip_random)
                        end
                        if (hq_upgrade == 'nanomine')
                            and (total_food < total_gold) and (total_gold >= 8)
                        then
                            hq_rating = hq_rating + UTLS.random_between(100, 200, skip_random)
                        end
                    end

                    if (hq_upgrade == 'lab') and (n_science >= 4) then
                        hq_rating = hq_rating + UTLS.random_between(100, 200, skip_random)
                    end
                end

                -- Essential upgrades are those with a rating >= 100 (before adding the minor ratings)
                local is_essential = hq_rating >= 100

                if is_essential and (planet.variables.colonised == 'homeworld') then
                    hq_rating = hq_rating * homeworld_factor
                end

                -- We still need a very small random contribution for those upgrades that do not get a bonus
                hq_rating = hq_rating + minor_rating + UTLS.random_between(0, 0.01, skip_random)

                -- Only allow expensive upgrades if they are essential
                local is_expensive = cost > available_gold
                if is_expensive and (not is_essential) then
                    hq_rating = -1e6
                end

                --std_print(string.format(UTLS.unit_str(hq) ..' %20s  %3dg  %8.3f  %s %s', hq_upgrade, cost, hq_rating, tostring(is_essential), tostring(is_expensive)))
                if (hq_rating > max_rating) then
                    max_rating = hq_rating
                    best_upgrade = {
                        x = hq.x, y = hq.y,
                        utype = hq_upgrade,
                        cost = cost,
                        is_essential = is_essential,
                        is_expensive = is_expensive,
                        score = ca_score,
                        rating = hq_rating
                    }
                end
            end
        end


        ------ Planet upgrades ------
        --std_print('  -- Planet upgrades --')
        local adj_ships = UTLS.get_ships {
            { 'filter_side', { { 'enemy_of', {side = wesnoth.current.side } } } },
            { 'filter_adjacent', { x = planet.x, y = planet.y } }
        }
        --std_print('    #adj_ships: ' .. #adj_ships)

        local close_ships_3 = UTLS.get_ships {
            { 'filter_side', { { 'enemy_of', {side = wesnoth.current.side } } } },
            { 'filter_location', { x = planet.x, y = planet.y, radius = 3 } }
        }
        --std_print('    #close_ships_3: ' .. #close_ships_3)

        local close_ships_4 = UTLS.get_ships {
            { 'filter_side', { { 'enemy_of', {side = wesnoth.current.side } } } },
            { 'filter_location', { x = planet.x, y = planet.y, radius = 4 } }
        }
        --std_print('    #close_ships_4: ' .. #close_ships_4)

        local close_planets_4 = UTLS.get_planets {
            { 'filter_side', { { 'enemy_of', {side = wesnoth.current.side } } } },
            { 'filter_location', { x = planet.x, y = planet.y, radius = 4 } }
        }
        --std_print('    #close_planets_4: ' .. #close_planets_4)

        local with_antimatter_weapon = false
        for _,ship in ipairs(close_ships_3) do
            if ship:matches { { 'has_attack', { type = 'antimatter' } } } then
                with_antimatter_weapon = true
                --std_print('    anitmatter weapon: ' .. UTLS.unit_str(ship))
            end
        end

        for planet_upgrade,cost in pairs(all_upgrades.planet) do
            local is_available = UPGRD.show_item(planet_upgrade)

            if is_available and (cost <= available_gold_expensive) then
                local planet_rating = planet_base_rating

                -- Bonus for defensive upgrades
                -- This is a minor bonus, others may go on top of it below
                if string.find('gaiacology/defence_laser/missile_base/shields/jammer/reflector', planet_upgrade) then
                    planet_rating = planet_rating + planet_defensive_upgrade_bonus
                end

                if (planet.hitpoints < planet.max_hitpoints) or with_antimatter_weapon then
                    if (planet_upgrade == 'gaiacology') then
                        planet_rating = planet_rating + UTLS.random_between(1000 + 20 * (1 + #adj_ships), nil, skip_random)
                    end
                end

                if (#close_ships_3 >= 2) then
                    if with_antimatter_weapon then
                        if (planet_upgrade == 'defence_laser') then
                            planet_rating = planet_rating + UTLS.random_between(100 + 20 * (1 + #close_ships_3), 200, skip_random)
                        end
                    else
                        if (planet_upgrade == 'missile_base') then
                            planet_rating = planet_rating + UTLS.random_between(100 + 20 * (1 + #close_ships_3), 200, skip_random)
                        end
                    end
                    if (planet_upgrade == 'shields') then
                        planet_rating = planet_rating + UTLS.random_between(100 + 10 * (1 + #close_ships_3), 200, skip_random)
                    end
                end

                if (#close_ships_4 >= 4) or (#close_planets_4 > 0) then
                    if string.find('spacedock/launch_pad/jammer/reflector', planet_upgrade) then
                        planet_rating = planet_rating + UTLS.random_between(100 + 10 * (1 + #close_ships_4), 200, skip_random)
                    end
                end

                -- Do not buy trade hub if planet is not at max population, otherwise make it essential
                if (planet_upgrade == 'trade_hub') then
                    if (hq.variables.population_current < hq.variables.population_max) then
                        planet_rating = planet_rating - 1e6
                    else
                        planet_rating = planet_rating + UTLS.random_between(100, 200, skip_random)
                    end
                end

                -- Essential upgrades are those with a rating > 100 (before adding the minor ratings)
                local is_essential = planet_rating > 100

                if is_essential and (planet.variables.colonised == 'homeworld') then
                    planet_rating = planet_rating * homeworld_factor
                end

                -- We still need a very small random contribution for those upgrades that do not get a bonus
                planet_rating = planet_rating + minor_rating + UTLS.random_between(0, 0.01, skip_random)

                -- Only allow expensive upgrades if they are essential
                local is_expensive = cost > available_gold
                if is_expensive and (not is_essential) then
                    planet_rating = -1e6
                end

                --std_print(string.format(UTLS.unit_str(planet) ..' %20s  %3dg  %8.3f  %s %s', planet_upgrade, cost, planet_rating, tostring(is_essential), tostring(is_expensive)))
                if (planet_rating > max_rating) then
                    max_rating = planet_rating
                    best_upgrade = {
                        x = planet.x, y = planet.y,
                        utype = planet_upgrade,
                        cost = cost,
                        is_essential = is_essential,
                        is_expensive = is_expensive,
                        score = ca_score,
                        rating = planet_rating
                    }
                end
            end
        end

        wml.variables.hq = nil
        wml.variables.planet = nil
    end


    ------ Ship upgrades ------
    --std_print('  -- Ship upgrades --')
    local all_ships = UTLS.get_ships {
        side = wesnoth.current.side,
        { 'not', { type = 'Terran Probe,Iildari Probe' } }
    }
    --std_print('#all_ships: ' .. #all_ships)

    local spacedocks = UTLS.get_spacedocks { side = wesnoth.current.side }
    --std_print('#spacedocks: ' .. #spacedocks)


    -- Ships can be upgraded if they satisfy all of the following:
    -- - can only have as many upgrades as their level
    -- - are either
    --     within reach of a spacedock and have >=75% of their HP
    --     or are next to a spacedock with no moves left, independent of the HP
    local ships, ship_moves = {}, {}
    for _,ship in ipairs(all_ships) do
        --std_print(UTLS.unit_str(ship), ship.variables.gadgets)
        if (ship.variables.gadgets < ship.level) then
            local max_rating_hex, best_hex = -math.huge
            if (ship.moves == 0) then
                for _,spacedock in ipairs(spacedocks) do
                    if (wesnoth.map.distance_between(ship, spacedock) == 1) then
                        best_hex = { ship.x, ship.y }
                    end
                end
            elseif (ship.hitpoints >= 0.75 * ship.max_hitpoints) then
                local reachmap = AH.get_reachmap(ship, { exclude_occupied = true })
                for _,spacedock in ipairs(spacedocks) do
                    for xa,ya in H.adjacent_tiles(spacedock.x, spacedock.y) do
                        local moves_left = reachmap:get(xa, ya)
                        if moves_left then
                            --std_print(UTLS.loc_str(xa, ya), moves_left)
                            if (max_rating_hex < moves_left) then
                                max_rating_hex = moves_left
                                best_hex = { xa, ya }
                            end
                        end
                    end
                end
            end
            if best_hex then
                --std_print('  best hex: ' .. UTLS.loc_str(best_hex))
                table.insert(ships, ship)
                ship_moves[ship.id] = best_hex
            end
        end
    end
    --std_print('#ships: ' .. #ships)
    --DBG.dbms(ship_moves, false, 'ship_moves')

    for _,ship in ipairs(ships) do
        --std_print('ship: ' .. UTLS.unit_str(ship))

        -- For the filter to work, the ship needs to be stored as 'ship' in WML
        wml.fire("store_unit", { variable="ship", { "filter", { id = ship.id } } })

        local minor_rating_ship = UTLS.random_between(ship.level, 4, skip_random)
        --std_print('minor_rating_ship ' .. UTLS.unit_str(ship) .. ': ' .. minor_rating_ship)

        for ship_upgrade,cost in pairs(all_upgrades.ship) do
            local is_available = UPGRD.show_item(ship_upgrade, true)

            if is_available and (cost <= available_gold_expensive) then
                local ship_rating = ship_base_rating

                if ship:matches { ability = 'transport' } then
                    if (ship_upgrade == 'turbocharger') then
                        ship_rating = ship_rating + UTLS.random_between(150, 200, skip_random)
                    end
                    if (ship_upgrade == 'cloak') then
                        ship_rating = ship_rating + UTLS.random_between(125, 200, skip_random)
                    end
                    if string.find('armour/displacer/slipstream/slingshot', ship_upgrade) then
                        ship_rating = ship_rating + UTLS.random_between(100, 200, skip_random)
                    end
                end

                if (ship_upgrade == 'slipstream') then
                    if ship:matches { { 'has_attack', { special_id = 'backstab' } } } then
                        ship_rating = ship_rating + UTLS.random_between(100, 200, skip_random)
                    end
                    if (ship.max_moves < 5) then
                        ship_rating = ship_rating - 1e6
                    end
                end

                if (ship_upgrade == 'cloak') and ship:matches { ability_type = 'hides' } then
                    ship_rating = ship_rating - 1e6
                end

                if (ship_upgrade == 'turbocharger') and (ship.max_moves >= 6) then
                    ship_rating = ship_rating - 1e6
                end

                -- Ignore all of the following upgrades (could not be used effectively by the AI)
                if string.find('tractor_beam/assault_pod/bio_bomb', ship_upgrade) then
                    ship_rating = ship_rating - 1e6
                end

                if ship:matches { ability = 'flagship' } then
                    -- If the flagship does not already have one of these defensive upgrades, give the
                    -- bonus to all, the random contribution will then decide between them
                    -- Since the flagship gets a bonus anyway, we don't need to give one for other upgrades
                    if string.find('armour/cloak/autofix_ship/displacer', ship_upgrade)
                        and (not ship:matches { ability = 'ship_armour' })
                        and (not ship:matches { ability = 'cloak' })
                        and (not ship:matches { ability_type = 'regenerate' })
                        and (not ship:matches { ability = 'displacer' })
                    then
                        ship_rating = ship_rating + UTLS.random_between(100, 200, skip_random)
                    end
                end

                -- Essential upgrades are those with a rating > 100 (before adding the minor ratings)
                local is_essential = ship_rating > 100

                if is_essential and ship:matches { ability = 'flagship' } then
                    ship_rating = ship_rating * flagship_factor
                end

                -- We still need a very small random contribution for those upgrades that do not get a bonus
                ship_rating = ship_rating + minor_rating_ship + UTLS.random_between(0, 0.01, skip_random)

                -- Only allow expensive upgrades if they are essential
                local is_expensive = cost > available_gold
                if is_expensive and (not is_essential) then
                    ship_rating = -1e6
                end

                local score_ship = ca_score_ship
                if ship:matches { ability = 'flagship' } then
                    score_ship = ca_score_flagship
                end

                --std_print(string.format(UTLS.unit_str(ship) .. ' %20s  %3dg  %9.4f  %s %s', ship_upgrade, cost, ship_rating, tostring(is_essential), tostring(is_expensive)))
                if (ship_rating > max_rating) then
                    max_rating = ship_rating
                    best_upgrade = {
                        x = ship.x, y = ship.y,
                        utype = ship_upgrade,
                        cost = cost,
                        is_essential = is_essential,
                        is_expensive = is_expensive,
                        score = score_ship,
                        rating = ship_rating
                    }

                    if (ship_moves[ship.id][1] ~= ship.x) or (ship_moves[ship.id][2] ~= ship.y) then
                        best_upgrade.moveto = ship_moves[ship.id]
                    end

                end
            end
        end

        wml.variables.ship = nil
    end
    --DBG.dbms(best_upgrade, false, 'best_upgrade')

    -- Ignore upgrades with negative ratings
    -- This could also be done by initializing max_rating to zero or by adding it
    -- to the conditional below. It's done here separately for added clarity.
    if best_upgrade and (best_upgrade.rating < 0) then best_upgrade = nil end
    --DBG.dbms(best_upgrade, false, 'best_upgrade')

    if (not best_upgrade) then
        DBG.print_debug_eval(ca_name, 0, start_time, 'no affordable upgrade found')
        return 0
    end

    DBG.print_debug_eval(ca_name, best_upgrade.score, start_time, 'best upgrade: ' .. UTLS.loc_str(best_upgrade) .. ' ' .. best_upgrade.utype .. ' (' .. best_upgrade.cost .. ' gold)')

    return best_upgrade.score
end

function ca_GE_upgrade:execution(cfg, data, ai_debug)
    local ai = ai or ai_debug

    -- Set the variables that count how much gold has been spent on upgrades
    if best_upgrade.is_essential then
        data.upgrades_gold = data.upgrades_gold + best_upgrade.cost
    else
        data.upgrades_gold = data.turn_start_gold + 1 -- install only one non-essential upgrade
    end

    -- Only allow one expensive upgrade per turn
    if best_upgrade.is_expensive then
        data.allow_expensive_upgrades = false  -- important: this needs to be set to false, not nil
        --std_print('no more expensive upgrades this turn')
    end

    local unit = wesnoth.units.get(best_upgrade.x, best_upgrade.y)

    -- First, if this is a ship that needs to be moved, do that
    if best_upgrade.moveto then
        local str = unit.id .. ' --> ' .. UTLS.loc_str(best_upgrade.moveto)
        DBG.print_debug_exec(ca_name, str)
        UTLS.output_add_move(str)
        AH.robust_move_and_attack(ai, unit, best_upgrade.moveto, nil, { partial_move = true })

        -- Check whether the unit actually made it there (there could have been an ambush)
        if (unit.x ~= best_upgrade.moveto[1]) or (unit.y ~= best_upgrade.moveto[2]) then
            std_print('move interrupted; skipping upgrade')
            best_upgrade = nil
            return
        end

        best_upgrade.x = unit.x
        best_upgrade.y = unit.y
    end

    local str = best_upgrade.utype .. ': ' .. UTLS.unit_str(unit) .. ' with ' .. best_upgrade.utype .. ' (' .. best_upgrade.cost .. '/' .. wesnoth.sides[wesnoth.current.side].gold .. ' gold)'
    if best_upgrade.is_expensive then str = str .. ' -- expensive' end
    DBG.print_debug_exec(ca_name, str)
    UTLS.output_add_move(str)
    --wesnoth.message('S' .. wesnoth.current.side .. ' T' .. wesnoth.current.turn, str)

    -- Check whether gold changed, to prevent infinite loops in case something goes wrong
    local gold_before = wesnoth.sides[wesnoth.current.side].gold

    wesnoth.sync.invoke_command('GEAI_buy_upgrade', best_upgrade)

    local gold_after = wesnoth.sides[wesnoth.current.side].gold
    --std_print('gold before, after:', gold_before, gold_after)
    if (gold_before ~= gold_after + best_upgrade.cost) then
        data.GEAI_abort = true
        DBG.error('apply upgrade', str)
    else
        UTLS.force_gamestate_change(ai)
    end

    best_upgrade = nil
end

return ca_GE_upgrade

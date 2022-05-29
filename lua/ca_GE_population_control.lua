----- CA: population_control -----
--
-- Description:
--   Change which unit types each HQ produces, based on the priorities defined in GEAI_config.lua

local ca_name = 'population_control'

local new_types
local ca_GE_population_control = {}

function ca_GE_population_control:evaluation(cfg, data)
    local ca_score = CFG.get_cfg_parm('CA_scores')[ca_name]
    if (ca_score < 0) or data.GEAI_abort then return 0 end

    local start_time = wesnoth.ms_since_init() / 1000.
    DBG.print_debug_eval(ca_name, 0, start_time, 'begin eval')


    new_types = {}

    local empire = wml.variables['empire[' .. wesnoth.current.side .. ']']
    --DBG.dbms(empire, false, 'empire')
    local population_priorities = CFG.get_cfg_parm('population_priorities')[empire.faction]
    --DBG.dbms(population_priorities, false, 'population_priorities')
    local sum_priorities = 0
    for _,priority in pairs(population_priorities) do sum_priorities = sum_priorities + priority end

    local headquarters = UTLS.get_headquarters { side = wesnoth.current.side }
    --std_print('#headquarters: ' .. #headquarters)

    --DBG.dbms(population_fractions, false, 'population_fractions')
    --DBG.dbms(unit2population, false, 'unit2population')

    local enemy_transports = AH.get_attackable_enemies { ability = 'transport' }
    --std_print('#enemy_transports', #enemy_transports)

    for _,hq  in ipairs(headquarters) do
        local planet = UTLS.get_planet_from_unit(hq)
        --std_print('\n----- ' .. UTLS.unit_str(hq) .. ' <--> ' .. UTLS.unit_str(planet) .. ' -----')

        local population = {
            work_unit = { n = 0 },
            science_unit = { n = 0 },
            combat_unit = { n = 0 }
        }
        for pop_type,priority in pairs(population_priorities) do
            population[pop_type].desired_fraction = priority / sum_priorities
            population[pop_type].base_type = empire[pop_type]
        end
        --DBG.dbms(population, false, 'population')

        -- Find how many units there are of each type
        local units = UTLS.get_units_on_planet(planet, {
            side = wesnoth.current.side,
            { 'not', { id = hq.id } }
        })
        for _,unit in ipairs(units) do
            if unit:matches { ability = 'work' } then
                population.work_unit.n = population.work_unit.n + 1
            elseif unit:matches { ability = 'science' } then
                population.science_unit.n = population.science_unit.n + 1
            else
                population.combat_unit.n = population.combat_unit.n + 1
            end
        end
        --DBG.dbms(population, false, 'population')

        -- If the population is >50% of population_max, derate workers
        local percent_full = #units / planet.variables.population_max
        --std_print('percent_full', percent_full)
        if (percent_full > 0.5) then
            -- derate_worker goes from 1 at percent_full=0.5 to 0 at percent_full=1
            local derate_worker = (1 - percent_full) * 2
            --std_print('derate_worker', derate_worker)
            population.work_unit.desired_fraction = population.work_unit.desired_fraction * derate_worker
        end
        --DBG.dbms(population, false, 'population')

        -- If many research fields are advanced already, derate scientists
        local research_priorities = CFG.get_cfg_parm('research_priorities')
        --DBG.dbms(research_priorities, false, 'research_priorities')
        local total_research = 0
        for field,priority in pairs(research_priorities) do
            total_research = total_research + empire['research_' .. field]
        end
        --std_print('total_research', total_research)
        if (total_research > 8) then
            -- derate_scientist goes from 1 at total_research=8 to 0 at total_research=12
            local derate_scientist = (12 - total_research) / 4
            --std_print('derate_scientist', derate_scientist)
            population.science_unit.desired_fraction = population.science_unit.desired_fraction * derate_scientist
        end
        --DBG.dbms(population, false, 'population')

        -- If there are enemies on the planet, increase importance of soldiers
        local enemies = UTLS.get_units_on_planet(planet, {
            { 'filter_side', { { 'enemy_of', {side = wesnoth.current.side } } } }
        })
        --std_print('  #enemies: ' .. #enemies)

        -- Also if an enemy transport with passengers is within two times its max_moves of the planet
        local close_enemy_transport = false
        for _,transport in ipairs(enemy_transports) do
            if (wesnoth.map.distance_between(transport, planet) <= transport.max_moves * 2)
                and (transport.attacks[1].damage > 0) -- number of passengers
            then
                --std_print('close transport: ' .. UTLS.unit_str(transport), UTLS.unit_str(planet), transport.attacks[1].damage)
                close_enemy_transport = true
                break
            end
        end

        if (#enemies > 0) or close_enemy_transport then
            population.combat_unit.desired_fraction = population.combat_unit.desired_fraction * 2
        end
        --DBG.dbms(population, false, 'population')

        -- Need to renormalize the fractions now
        local sum_fractions = 0
        for _,pop in pairs(population) do sum_fractions = sum_fractions + pop.desired_fraction end
        for _,pop in pairs(population) do
            pop.desired_fraction = pop.desired_fraction / sum_fractions
        end
        --DBG.dbms(population, false, 'population')


        -- Base rating is simply the number of units missing based on the ideal ratio
        -- The +1 is because the ratio needs to be based on the situation once the current
        -- unit is produced; but more importantly, so that it works when #units == 0
        for _,pop in pairs(population) do
            pop.rating = pop.desired_fraction * (#units + 1) - pop.n
        end
        --DBG.dbms(population, false, 'population')

        -- If there is an artifact, but no scientists on the planet, strongly prefer creating a scientist
        --std_print('  #scientists: ' .. population.science_unit.n)
        if (population.science_unit.n == 0) then
            local artifact_locs = UTLS.get_artifact_locs(UTLS.filter_planet_hexes(planet))
            --DBG.dbms(artifact_locs, false, 'artifact_locs')
            if (#artifact_locs > 0) then
                --std_print('    artifact found on planet: ' .. UTLS.unit_str(planet))
                population.science_unit.rating = population.science_unit.rating + 100
            end
        end
        --DBG.dbms(population, false, 'population on ' .. planet.id)

        local max_rating = - math.huge
        for _,pop in pairs(population) do
            if (pop.rating > max_rating) then
                max_rating = pop.rating
                best_type = pop.base_type
            end
        end
        --std_print('    best_type: ' .. best_type, max_rating)

        -- Compare new type to current type
        local current_type = hq.variables.population_preference
        local current_pop_type
        if (current_type == 'Vendeeni Sliverer') then
            current_pop_type = 'combat_unit'
        else
            for pop_type,pop in pairs(population) do
                if (current_type == pop.base_type) then
                    current_pop_type = pop_type
                    break
                end
            end
        end
        --std_print(UTLS.unit_str(hq) .. ' current_type: ' .. current_type .. ', current_pop_type: ' .. current_pop_type )

        -- This is important: We do not want to add the random tie breaker if the current
        -- unit type has the maximum rating. Otherwise the AI might switch back and
        -- forth between types with the same (or very similar) ratings.
        if (population[current_pop_type].rating == max_rating) then
            --std_print('  Current type (' .. current_type .. ') has minimum rating. Do not change.')
        else -- otherwise we go through the loop again and now add a minor random rating
            local max_rating = -math.huge
            for pop_type,pop in pairs(population) do
                local rating = pop.rating + math.random() / 100
                --std_print('  total rating ' .. pop_type .. ': ' .. rating)

                if (rating > max_rating) then
                    max_rating = rating
                    new_types[hq.id] = pop.base_type

                    -- For Vendeeni, if they have a genepod and the unit to be built is a combat_unit,
                    -- randomly choose between Fighter and Sliverer, but only if no enemy faction is Iildari
                    if (pop_type == 'combat_unit') and (empire.faction == 'Vendeeni') and hq.variables.genepod then
                        --std_print('  AI side is Vendeeni with genepod. Considering Sliverer.')
                        local have_iildari = false
                        for other_side,other_empire in pairs(wml.array_access.get('empire')) do
                            if (other_side > 1) then -- The empire variable starts at 0 with an empty entry
                                -- The '-1' is because of the difference between WML and Lua indexing
                                if (other_empire.faction == 'Iildari') and wesnoth.sides.is_enemy(other_side - 1, wesnoth.current.side) then
                                    have_iildari = true
                                    break
                                end
                            end
                        end
                        if have_iildari then
                            --std_print('  Iildari faction found. Skipping Sliverer.')
                        else
                            if (math.random(2) == 2) then
                                new_types[hq.id] = 'Vendeeni Sliverer'
                            end
                        end
                    end
                end
            end
            --std_print('    best_type: ' .. new_types[hq.id], max_rating)
        end
    end
    --DBG.dbms(new_types, false, 'new_types')

    if (not next(new_types)) then
        DBG.print_debug_eval(ca_name, 0, start_time, 'found no population settings to be changed')
        return 0
    end

    DBG.print_debug_eval(ca_name, ca_score, start_time, 'found population settings to be changed')
    return ca_score
end

function ca_GE_population_control:execution(cfg, data, ai_debug)
    local ai = ai or ai_debug

    for hq_id,unit_type in pairs(new_types) do
        local hq = wesnoth.units.find_on_map { id = hq_id }[1]

        local str = 'change ' .. UTLS.unit_str(hq) .. ' to produce ' .. unit_type
        DBG.print_debug_exec(ca_name, str)
        UTLS.output_add_move(str)

        local cfg = { x = hq.x, y = hq.y, unit_type = unit_type }
        wesnoth.sync.invoke_command('GEAI_population_control', cfg)

        local new_type = hq.variables.population_preference
        if (new_type ~= unit_type) then
            data.GEAI_abort = true
            DBG.error('population control', str)
        else
            UTLS.force_gamestate_change(ai)
        end
    end

    new_types = {}
end

return ca_GE_population_control

----- CA: recruit -----
--
-- Description:
--   Recruits combat ships; transporters are recruited by the transport_troops CA

local ca_name = 'recruit'

local best_recruit
local ca_GE_recruit = {}

function ca_GE_recruit:evaluation(cfg, data)
    local ca_score = CFG.get_cfg_parm('CA_scores')[ca_name]
    if (ca_score < 0) or data.GEAI_abort then return 0 end

    local start_time = wesnoth.ms_since_init() / 1000.
    DBG.print_debug_eval(ca_name, 0, start_time, 'begin eval')


    best_recruit = nil

    -- If the done_recruiting flag is set, exit right away
    -- This happens if the unit type determined in a previous call to the recruiting CA
    -- turned out to be too expensive
    if data.done_recruiting then
        DBG.print_debug_eval(ca_name, 0, start_time, 'previously determined that recruiting was finished')
        return 0
    end

    -- Find all ship types on the recruit list
    local recruit_types = {}
    for _,recruit_id in ipairs(wesnoth.sides[wesnoth.current.side].recruit) do
        --std_print('  possible recruit: ' .. recruit_id)
        local is_transport = false
        local abilities = wml.get_child(wesnoth.unit_types[recruit_id].__cfg, "abilities")
        if abilities then
            for ability in wml.child_range(abilities, 'dummy') do
                if (ability.id == 'transport') then
                    --std_print('    -- is transport')
                    is_transport = true
                    break
                end
            end
        end

        -- Exclude transports (handled by the move_troops CA)
        -- Also exclude probes, as they are not useful for the AI
        if (not is_transport) and (recruit_id ~= 'Iildari Probe') and (recruit_id ~= 'Terran Probe') then
            -- We do not (yet) check whether we can afford the units
            recruit_types[recruit_id] = true
        end
    end
    --DBG.dbms(recruit_types, false, 'recruit_types')

    if (not next(recruit_types)) then
        DBG.print_debug_eval(ca_name, 0, start_time, 'no more gold to spend on recruits')
        return 0
    end

    -- Probability of recruiting a ship decreases if the AI already has units of that type
    local recruit_probs, sum_probs = {}, 0
    for recruit_id,_ in pairs(recruit_types) do
        local ships = wesnoth.units.find_on_map {
            side = wesnoth.current.side,
            type = recruit_id
        }
        local prob = 1 / ( 1 + #ships)
        sum_probs = sum_probs + prob
        recruit_probs[recruit_id] = prob
    end
    local prob_start = 0
    for id,prob in pairs(recruit_probs) do
        local cost = wesnoth.unit_types[id].cost
        local norm_prob = prob / sum_probs
        recruit_probs[id] = { prob_i = prob_start, prob_f = prob_start + norm_prob, cost = cost }
        prob_start = prob_start + norm_prob
    end
    --DBG.dbms(recruit_probs, false, 'recruit_probs')


    -- The preferred recruit location is the empty castle hex that is closest
    -- to the nearest enemy ship
    local recruit_locs = UTLS.get_recruit_locs()
    --DBG.dbms(recruit_locs, false, 'recruit_locs')

    if (#recruit_locs == 0) then
        DBG.print_debug_eval(ca_name, 0, start_time, 'no open castle hexes for recruiting')
        return 0
    end

    local enemy_ships = UTLS.get_ships {
        { 'filter_side', { { 'enemy_of', {side = wesnoth.current.side } } } }
    }
    --for _,ship in ipairs(enemy_ships) do std_print(UTLS.unit_str(ship)) end

    if (#enemy_ships == 0) then
        DBG.print_debug_eval(ca_name, 0, start_time, 'no enemy ships')
        return 0
    end

    -- For now, we just use the hex closest to any enemy ship as recruit hex
    local min_dist, best_loc = math.huge
    for _,loc in ipairs(recruit_locs) do
        for _,ship in ipairs(enemy_ships) do
            local dist = wesnoth.map.distance_between(ship, loc)
            --std_print(UTLS.loc_str(loc) .. ' ' .. UTLS.unit_str(ship) .. ' ' .. dist)
            if (dist < min_dist) then
                min_dist = dist
                best_loc = loc
            end
        end
    end
    --std_print('best_loc: ' .. UTLS.loc_str(best_loc))

    -- Choose unit type to be recruited randomly
    local rnd = math.random()
    for id,prob in pairs(recruit_probs) do
        if (rnd >= prob.prob_i) and (rnd < prob.prob_f) then
            best_recruit = { type = id, loc = best_loc, cost = prob.cost }
            break
        end
    end
    --DBG.dbms(best_recruit, false, 'best_recruit')

    -- If this unit type is to expensive, set the done_recruiting flag, so
    -- that subsequent calls to the recruiting CA do not override this
    if (best_recruit.cost > wesnoth.sides[wesnoth.current.side].gold) then
        DBG.print_debug_eval(ca_name, 0, start_time, 'best recruit ' .. best_recruit.type .. ' is too expensive')
        data.done_recruiting = true
        return 0
    end

    DBG.print_debug_eval(ca_name, ca_score, start_time, 'best_recruit: ' .. best_recruit.type .. ' at ' .. UTLS.loc_str(best_recruit.loc))
    return ca_score
end

function ca_GE_recruit:execution(cfg, data, ai_debug)
    local ai = ai or ai_debug

    local str = 'recruiting ' .. best_recruit.type .. ' at ' .. UTLS.loc_str(best_recruit.loc)
    DBG.print_debug_exec(ca_name, str)
    UTLS.output_add_move(str)

    AH.checked_recruit(ai, best_recruit.type, best_recruit.loc[1], best_recruit.loc[2])
    best_recruit = nil
end

return ca_GE_recruit

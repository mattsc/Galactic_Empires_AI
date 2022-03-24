----- CA: research -----
--
-- Description:
--   Advance a research field to the next tier, if there are sufficient research points

local ca_name = 'research'

local max_research_level = 3
local unlock_cost = 10

local best_research_field, unlock_tier
local ca_GE_research = {}

function ca_GE_research:evaluation(cfg, data)
    local ca_score = CFG.get_cfg_parm('CA_scores')[ca_name]
    if (ca_score < 0) or data.GEAI_abort then return 0 end

    local start_time = wesnoth.ms_since_init() / 1000.
    DBG.print_debug_eval(ca_name, 0, start_time, 'begin eval')


    best_research_field, unlock_tier = nil, nil

    local empire = wml.variables['empire[' .. wesnoth.current.side .. ']']
    --DBG.dbms(empire, false, 'empire')

    -- Check whether there are enough RP to unlock another research tier
    if (empire.research_points < unlock_cost) then
        DBG.print_debug_eval(ca_name, 0, start_time, 'not enough research points: ' .. empire.research_points)
        return 0
    end

    -- Read the configuration parameters
    local research_priorities = CFG.get_cfg_parm('research_priorities')
    --DBG.dbms(research_priorities, false, 'research_priorities')

    local max_rating = - math.huge
    for field,priority in pairs(research_priorities) do
        local research_level = empire['research_' .. field]

        if (research_level < max_research_level) then
            -- Prefer fields that are less advanced, and weigh according to the
            -- priorities set in the config file
            local rating = (max_research_level - research_level) * priority

             -- Small random tie breaker
            rating = rating + math.random() / 100
            --std_print(field, research_level, rating)

            if (rating > max_rating) then
                max_rating = rating
                best_research_field = field
                unlock_tier = research_level + 1
            end
        end
    end

    -- This happens if all research fields are at maximum already
    if (not best_research_field) then
        DBG.print_debug_eval(ca_name, 0, start_time, 'all fields at maximum level already')
        return 0
    end

    DBG.print_debug_eval(ca_name, ca_score, start_time, 'unlock research_' .. best_research_field .. ' tier ' .. unlock_tier)
    return ca_score
end

function ca_GE_research:execution(cfg, data, ai_debug)
    local ai = ai or ai_debug

    local str = 'unlocking research_' .. best_research_field .. ' tier ' .. unlock_tier
    DBG.print_debug_exec(ca_name, str)
    UTLS.output_add_move(str)

    -- Set the research field variable to the new value
    local variable_cfg = {
        name = 'empire[' .. wesnoth.current.side .. '].research_' .. best_research_field,
        value = unlock_tier
    }
    wesnoth.sync.invoke_command('GEAI_set_variable', variable_cfg)

    -- Subtract the research points needed for this
    local research_points_before = wml.variables['empire[' .. wesnoth.current.side .. '].research_points']
    local variable_cfg = {
        name = 'empire[' .. wesnoth.current.side .. '].research_points',
        value = research_points_before - unlock_cost
    }
    wesnoth.sync.invoke_command('GEAI_set_variable', variable_cfg)

    local research_points_after = wml.variables['empire[' .. wesnoth.current.side .. '].research_points']
    --std_print('research points before, after:', research_points_before, research_points_after)
    if (research_points_after ~= research_points_before - unlock_cost) then
        data.GEAI_abort = true
        DBG.error('research', str)
    else
        UTLS.force_gamestate_change(ai)
    end

    best_research_field = nil
    unlock_tier = nil
end

return ca_GE_research

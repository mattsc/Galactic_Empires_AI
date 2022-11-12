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

    -- Also need to allow the recruits
    local allow_recruit = { side = wesnoth.current.side }
    if (best_research_field == 'ships') then
        local faction = wml.variables['empire[' .. wesnoth.current.side .. ']'].faction

        if (unlock_tier == 1) then
            if (faction == 'Terran') then allow_recruit.type = 'Terran Servicer,Terran Fighter,Terran Cruiser'
            elseif (faction == 'Vendeeni') then allow_recruit.type = 'Vendeeni Stinger,Vendeeni Mite,Vendeeni Wasp'
            elseif (faction == 'Iildari') then allow_recruit.type = 'Iildari Explorer,Iildari Fighter,Iildari Battery'
            elseif (faction == 'Dwartha') then allow_recruit.type = 'Dwartha Driller,Dwartha Sweeper'
            elseif (faction == 'Steelhive') then allow_recruit.type = 'Steelhive Oculus,Steelhive Infector,Steelhive Hedron'
            end
        elseif (unlock_tier == 2) then
            if (faction == 'Terran') then allow_recruit.type = 'Terran Probe,Terran Mechanic,Terran Seeker,Terran Interceptor,Terran Patrol,Terran Battleship'
            elseif (faction == 'Vendeeni') then allow_recruit.type = 'Vendeeni Clinger,Vendeeni Locust,Vendeeni Moth,Vendeeni Mayfly,Vendeeni War Wasp'
            elseif (faction == 'Iildari') then allow_recruit.type = 'Iildari Probe,Iildari Advanced Lookout,Iildari Advanced Explorer,Iildari Advanced Fighter,Iildari Advanced Battery'
            elseif (faction == 'Dwartha') then allow_recruit.type = 'Dwartha Pathfinder,Dwartha Rake,Dwartha Shifter,Dwartha Eliminator'
            elseif (faction == 'Steelhive') then allow_recruit.type = 'Steelhive Spotter,Steelhive Sparkgazer,Steelhive Corruptor,Steelhive Choron,Steelhive Tridron'
            end
        elseif (unlock_tier == 3) then
            if (faction == 'Terran') then allow_recruit.type = 'Terran Ranger,Terran Striker,Terran Guardian,Terran Destroyer'
            elseif (faction == 'Vendeeni') then allow_recruit.type = 'Vendeeni Mantis,Vendeeni Hornet,Vendeeni Mosquito,Vendeeni Death Wasp'
            elseif (faction == 'Iildari') then allow_recruit.type = 'Iildari Elite Lookout,Iildari Elite Explorer,Iildari Elite Fighter,Iildari Elite Battery'
            elseif (faction == 'Dwartha') then allow_recruit.type = 'Dwartha Beltrunner,Dwartha Trident,Dwartha Displacer,Dwartha Annihilator'
            elseif (faction == 'Steelhive') then allow_recruit.type = 'Steelhive Monitor,Steelhive Boltstriker,Steelhive Hexidron'
            end
        end

        wesnoth.sync.invoke_command('GEAI_allow_recruit', allow_recruit)
    end

    best_research_field = nil
    unlock_tier = nil
end

return ca_GE_research

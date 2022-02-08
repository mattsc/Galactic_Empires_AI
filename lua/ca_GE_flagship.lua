----- CA: flagship -----
--
-- Description:
--   Used to keep the flagship close to the homeworld
--   This is a modified version of the zone guardian Micro AI, mostly so that
--   planets do not count as enemies to be attacked

local ca_name = 'flagship'

local flagship_move
local ca_GE_flagship = {}

function ca_GE_flagship:evaluation(cfg, data)
    local ca_score = CFG.get_cfg_parm('CA_scores')[ca_name]
    local ca_score_move = CFG.get_cfg_parm('CA_scores')[ca_name .. '_move']
    if (ca_score < 0) or data.GEAI_abort then return 0 end

    local start_time = wesnoth.ms_since_init() / 1000.
    DBG.print_debug_eval(ca_name, 0, start_time, 'begin eval')


    flagship_move = nil

    local flagship = UTLS.get_flagships({ side = wesnoth.current.side }, true)[1]
    if (not flagship) then
        DBG.print_debug_eval(ca_name, 0, start_time, 'no flagship with moves on map')
        return 0
    end
    --std_print('flagship: ' .. UTLS.unit_str(flagship))

    local homeworld = UTLS.get_homeworlds { side = wesnoth.current.side }[1]
    --std_print('homeworld: ' .. UTLS.unit_str(homeworld))

    local enemies = AH.get_attackable_enemies {
        { 'not', { role = 'planet' } },
        { 'filter_location', { x = homeworld.x, y = homeworld.y, radius = 6 } }
    }
    --std_print('#enemies: ' .. #enemies)

    local reach = wesnoth.paths.find_reach(flagship)

    -- If there are enemies, try to attack them, or
    if enemies[1] then
        local min_dist, target = math.huge
        for _,enemy in ipairs(enemies) do
            local dist = wesnoth.map.distance_between(flagship.x, flagship.y, enemy.x, enemy.y)
            if (dist < min_dist) then
                target, min_dist = enemy, dist
            end
        end

        -- If a valid target was found, flagship attacks this target, or moves toward it
        if target then
            -- Find tiles adjacent to the target
            -- Save the one with the highest defense rating that flagship can reach
            local best_defense, attack_loc = - math.huge
            for xa,ya in H.adjacent_tiles(target.x, target.y) do
                -- Only consider unoccupied hexes
                local unit_in_way = wesnoth.units.get(xa, ya)
                if (not AH.is_visible_unit(wesnoth.current.side, unit_in_way))
                    or (unit_in_way == flagship)
                then
                    local defense = flagship:defense_on(wesnoth.current.map[{xa, ya}])
                    local nh = AH.next_hop(flagship, xa, ya)
                    if nh then
                        if (nh[1] == xa) and (nh[2] == ya) and (defense > best_defense) then
                            best_defense, attack_loc = defense, { xa, ya }
                        end
                    end
                end
            end

            -- If a valid hex was found: move there and attack
            if attack_loc then
                flagship_move = {
                    flagship = flagship,
                    moveto = attack_loc,
                    target = target
                }
                DBG.print_debug_eval(ca_name, ca_score, start_time, 'found enemy to be attacked by flagship')
                return ca_score
            else  -- Otherwise move toward that enemy
                -- Go through all hexes the flagship can reach, find closest to target
                -- Cannot use next_hop here since target hex is occupied by enemy
                local min_dist, nh = math.huge
                for _,hex in ipairs(reach) do
                    -- Only consider unoccupied hexes
                    local unit_in_way = wesnoth.units.get(hex[1], hex[2])
                    if (not AH.is_visible_unit(wesnoth.current.side, unit_in_way))
                        or (unit_in_way == flagship)
                    then
                        local dist = wesnoth.map.distance_between(hex[1], hex[2], target.x, target.y)
                        if (dist < min_dist) then
                            min_dist, nh = dist, { hex[1], hex[2] }
                        end
                    end
                end
                flagship_move = {
                    flagship = flagship,
                    moveto = nh
                }
                DBG.print_debug_eval(ca_name, ca_score, start_time, 'found enemy for flagship to move toward')
                return ca_score
            end
        end

    -- If no enemy around or within the zone, move toward station or zone
    else
        local locs_map = LS.of_pairs(AH.get_locations_no_borders({
            { 'and', { x = homeworld.x, y = homeworld.y, radius = 3 } },
            { 'not', { x = homeworld.x, y = homeworld.y, radius = 1 } }
        }))
        --std_print('locs_map:size(): ' .. locs_map:size())

        -- Check out which of those hexes the flagship can reach
        local reach_map = LS.of_pairs(reach)
        reach_map:inter(locs_map)

        -- If it can reach some hexes, use only reachable locations,
        -- otherwise move toward any (random) one from the entire set
        if (reach_map:size() > 0) then
            locs_map = reach_map
        end

        local locs = locs_map:to_pairs()

        local newpos
        if (#locs > 0) then
            local newind = math.random(#locs)
            newpos = { locs[newind][1], locs[newind][2] }
        else
            newpos = { flagship.x, flagship.y }
        end

        -- Next hop toward that position
        local nh = AH.next_hop(flagship, newpos[1], newpos[2])
        if nh then
            flagship_move = {
                flagship = flagship,
                moveto = nh
            }
            DBG.print_debug_eval(ca_name, ca_score_move, start_time, 'move flagship in zone')
            return ca_score_move
        end
    end

    DBG.print_debug_eval(ca_name, 0, start_time, 'no move found for flagship')
    return 0
end

function ca_GE_flagship:execution(cfg, data, ai_debug)
    local ai = ai or ai_debug

    local str = 'move ' .. flagship_move.flagship.id .. '  -->  ' .. UTLS.loc_str(flagship_move.moveto)
    if flagship_move.target then
        str = str .. ' and attack ' .. flagship_move.target.id .. ' ' .. UTLS.loc_str(flagship_move.target)
    end
    DBG.print_debug_exec(ca_name, str)
    UTLS.output_add_move(str)

    AH.robust_move_and_attack(ai, flagship_move.flagship, flagship_move.moveto, flagship_move.target) -- full move only

    unit_move = {}
end

return ca_GE_flagship

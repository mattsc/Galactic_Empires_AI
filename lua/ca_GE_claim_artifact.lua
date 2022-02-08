----- CA: claim_artifact -----
--
-- Description:
--   Move scientists toward artifacts
--
-- Limitations:
--  - If there are multiple scientists and artifacts are out of reach, they might all go
--    for the same artifact. Given that artifacts are only placed at the beginning of a
--    game at the moment, this is an unlikely situation. No need to change for now.

local ca_name = 'claim_artifact'

local best_unit, best_loc
local ca_GE_claim_artifact = {}

function ca_GE_claim_artifact:evaluation(cfg, data)
    local ca_score = CFG.get_cfg_parm('CA_scores')[ca_name]
    if (ca_score < 0) or data.GEAI_abort then return 0 end

    local start_time = wesnoth.ms_since_init() / 1000.
    DBG.print_debug_eval(ca_name, 0, start_time, 'begin eval')


    best_unit, best_loc = nil, nil

    local all_artifact_locs = UTLS.get_artifact_locs()
    --std_print('#all_artifact_locs: ' .. #all_artifact_locs)
    if (#all_artifact_locs == 0) then
        DBG.print_debug_eval(ca_name, 0, start_time, 'no artifacts on any planet')
        return 0
    end

    local all_planets = UTLS.get_planets()
    local max_rating = -math.huge
    for _,planet in ipairs(all_planets) do
        local planet_artifact_locs = UTLS.get_artifact_locs(UTLS.filter_planet_hexes(planet))
        --std_print(UTLS.unit_str(planet) .. ' #planet_artifact_locs: ' .. #planet_artifact_locs)

        for _,loc in ipairs(planet_artifact_locs) do
            -- If there is a unit on the artifact hex, it must be on the AI's side and be able to move away
            local unit = wesnoth.units.get(loc[1], loc[2])
            if (not unit) or ((unit.side == wesnoth.current.side) and (unit.moves > 0)) then
                local scientists = UTLS.get_scientists({
                    side = wesnoth.current.side,
                    role = planet.id
                }, true)
                for _,scientist in ipairs(scientists) do
                    local _,cost = wesnoth.paths.find_path(scientist, loc[1], loc[2])

                    rating = scientist.moves - cost
                    rating = rating + scientist.hitpoints / 100
                    rating = rating + math.random() / 100
                    --std_print(UTLS.unit_str(planet), UTLS.loc_str(loc), UTLS.unit_str(scientist), cost, rating)

                    if (rating > max_rating) then
                        max_rating = rating
                        best_unit = scientist
                        best_loc = loc
                    end
                end
            end
        end
    end

    if best_unit then
        local str = 'move ' .. UTLS.unit_str(best_unit) .. ' toward artifact at ' .. UTLS.loc_str(best_loc)
        DBG.print_debug_eval(ca_name, ca_score, start_time, str)
        return ca_score
    end

    DBG.print_debug_eval(ca_name, 0, start_time, 'found no claimable artifact')
    return 0
end

function ca_GE_claim_artifact:execution(cfg, data, ai_debug)
    local ai = ai or ai_debug

    local next_hop = AH.next_hop(best_unit, best_loc[1], best_loc[2], { ignore_own_units = true })
    if (not next_hop) then next_hop = { best_unit.x, best_unit.y } end

    local str = 'move ' .. UTLS.unit_str(best_unit) .. ' toward artifact at ' .. UTLS.loc_str(best_loc) .. ' --> ' .. UTLS.loc_str(next_hop)
    DBG.print_debug_exec(ca_name, str)
    UTLS.output_add_move(str)

    AH.robust_move_and_attack(ai, best_unit, next_hop, nil, { partial_move = true })

    best_unit, best_loc = nil, nil
end

return ca_GE_claim_artifact

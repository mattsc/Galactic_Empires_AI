----- CA: ground_combat -----
--
-- Description:
--   Attacks on aliens and alien headquarters, so that they happen
--   after attacks on enemy-side units, which are done by the default combat CA
--
--   Note: we do not exclude friendly aliens, as this CA is what takes care of
--     moving AI units next to them in order to turn them

local ca_name = 'ground_combat'

local best_combo
local ca_GE_ground_combat = {}

function ca_GE_ground_combat:evaluation(cfg, data, ai_debug)
    local ai = ai or ai_debug

    local ca_score = CFG.get_cfg_parm('CA_scores')[ca_name]
    if (ca_score < 0) or data.GEAI_abort then return 0 end

    local start_time = wesnoth.ms_since_init() / 1000.
    DBG.print_debug_eval(ca_name, 0, start_time, 'begin eval')


    best_combo = nil

    -- As mentioned above, include friendly aliens (well, at least until they are turned)
    local aliens = wesnoth.units.find_on_map {
        race = 'alien',
        { 'filter_side', { { 'enemy_of', {side = wesnoth.current.side } } } }
    }
    --std_print('#aliens: ' .. #aliens)

    -- Also add alien HQs, but add them at the end of the array. As enemies are dealt with
    -- in order in which they appear, aliens will be attacked first, then alien HQs.
    local hqs = UTLS.get_headquarters {
        { 'filter_side', {  -- this excludes neutral planets
            { 'not', { { 'has_unit', { canrecruit = 'yes' } } } }
        } }
    }
    --std_print('#hqs: ' .. #hqs)
    for _,hq in ipairs(hqs) do table.insert(aliens, hq) end
    --std_print('#aliens: ' .. #aliens)


    -- Just go through the aliens one by one and execute attacks as they are found, the order does not matter
    for _,alien in ipairs(aliens) do
        local attackers = AH.get_units_with_attacks {
            side = wesnoth.current.side,
            role = alien.role,
            { 'not', { has_weapon = 'food' }}
        }
        --std_print(UTLS.unit_str(alien) .. ': ' .. alien.role, #attackers)

        if (#attackers > 0) then
            local combos = AH.get_attack_combos(attackers, alien)
            --DBG.dbms(combos, false, 'combos')

            -- Aliens are strong and individual attack ratings could be negative,
            -- so we only keep combos with max number of attacks, so that units
            -- do not block hexes from other units in later attacks
            local max_number, max_attack_combos = 0, {}
            for _,combo in ipairs(combos) do
                local att_number = 0
                for dst,src in pairs(combo) do att_number = att_number + 1 end
                if (att_number > max_number) then
                    max_number = att_number
                    max_attack_combos = {}
                end
                if (att_number == max_number) then
                    table.insert(max_attack_combos, combo)
                end
            end
            --DBG.dbms(max_attack_combos, false, 'max_attack_combos')

            -- Many individual attacks will be the same, so cache evaluations as much as possible
            local attackers_xy, ratings = {}, {}
            local max_rating = -math.huge
            for _,combo in ipairs(max_attack_combos) do
                local combo_rating = 0
                for dst,src in pairs(combo) do
                    local dst_x, dst_y =  math.floor(dst / 1000), dst % 1000

                    if (not attackers_xy[src]) then
                        local src_x, src_y =  math.floor(src / 1000), src % 1000
                        attackers_xy[src] = wesnoth.units.get(src_x, src_y)
                    end

                    local dstsrc = dst .. src
                    local rating = ratings[dstsrc]
                    if (not rating) then
                        rating = BC.attack_rating(attackers_xy[src], alien, { dst_x, dst_y })
                        ratings[dstsrc] = rating
                    end
                    --std_print(_, src .. ' -> ' .. dst, rating)
                    combo_rating = combo_rating + rating
                end

                combo_rating = combo_rating + math.random() / 100
                --std_print('  -> ' .. combo_rating)

                if (combo_rating > max_rating) then
                    max_rating = combo_rating
                    best_combo = { target = { x = alien.x, y = alien.y } }

                    -- Also sort the individual attacks by their rating
                    for dst,src in pairs(combo) do
                        local dst_x, dst_y =  math.floor(dst / 1000), dst % 1000
                        local src_x, src_y =  math.floor(src / 1000), src % 1000
                        table.insert(best_combo, {
                            src = { x = src_x, y = src_y },
                            dst = { x = dst_x, y = dst_y },
                            rating = ratings[dst .. src]
                        })
                    end
                    table.sort(best_combo, function(a, b) return a.rating > b.rating end)
                end
            end
            --DBG.dbms(best_combo, false, 'best_combo: rating = ' .. max_rating)
        end

        -- Don't need to check the other aliens/planets, just do it one at a time
        if best_combo then
            DBG.print_debug_eval(ca_name, ca_score, start_time, 'found attack combo')
            return ca_score
        end
    end

    DBG.print_debug_eval(ca_name, 0, start_time, 'no attack found')
    return 0
end

function ca_GE_ground_combat:execution(cfg, data, ai_debug)
    local ai = ai or ai_debug

    local target = wesnoth.units.get(best_combo.target.x, best_combo.target.y)

    for _,attack in ipairs(best_combo) do
        local unit = wesnoth.units.get(attack.src.x, attack.src.y)

        local str = 'attack: ' .. UTLS.unit_str(unit) .. ' --> ' .. UTLS.unit_str(target) .. ' from ' .. UTLS.loc_str(attack.dst)
        DBG.print_debug_exec(ca_name, str)
        UTLS.output_add_move(str)

        AH.robust_move_and_attack(ai, attack.src, attack.dst, best_combo.target)

        if (not target) or (not target.valid)
            or (not wesnoth.sides.is_enemy(target.side, wesnoth.current.side))
        then break end

    end

    best_combo = nil
end

return ca_GE_ground_combat

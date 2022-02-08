----- CA: retreat_space -----
--
-- Description:
--   Retreat injured ships
--   For the most part, this uses the default AI's code, but with some
--   GE-specific modifications
--   Note: cannot use this for ground healing, as not all ground healers heal all types of units

local ca_name = 'retreat_space'

local retreat_factor = 0.25
local retreat_enemy_weight = 1.0


local function print_dbg(...)
    local show_debug_info = false -- manually set to true/false depending on whether output is desired
    if wesnoth.game_config.debug and show_debug_info then
        std_print('Retreat debug: ', ...)
    end
end

local function min_hp(unit)
    -- The minimum hp to retreat is a function of hitpoints and terrain defense
    -- We want to stay longer on good terrain and leave early on bad terrain
    -- It can be influenced by the 'retreat_factor' AI aspect

    -- Leaders are more valuable and should retreat earlier
    if unit.canrecruit then retreat_factor = retreat_factor * 1.5 end

    -- Higher retreat willingness on bad terrain
    local retreat_factor = retreat_factor * (100 - unit:defense_on(wesnoth.current.map[unit])) / 50

    local min_hp = retreat_factor * unit.max_hitpoints

    -- Account for poison damage on next turn
    if unit.status.poisoned then min_hp = min_hp + wesnoth.game_config.poison_amount end

    -- Large values of retreat_factor could cause fully healthy units to retreat.
    -- We require a unit to be down more than 10 HP, or half its HP for units with less than 20 max_HP.
    local max_hp = unit.max_hitpoints
    local max_min_hp = math.max(max_hp - 10, max_hp / 2)
    if (min_hp > max_min_hp) then
        min_hp = max_min_hp
    end

    local retreat_str = ''
    if (unit.hitpoints < min_hp) then retreat_str = '  --> retreat' end
    print_dbg(string.format('%-20s %3d/%-3d HP  threshold: %5.1f HP%s', unit.id, unit.hitpoints, unit.max_hitpoints, min_hp, retreat_str))

    return min_hp
end

local function get_healing_locations(possible_healers)
    local healing_locs = LS.create()
    for i,u in ipairs(possible_healers) do
        -- Only consider healers that cannot move this turn
        -- At the moment, planets have 1 MP: check for moves=0 does not work,
        -- also need a separate check whether this is a planet
        if (u.moves == 0) or (u.role == 'planet') or (u.side ~= wesnoth.current.side) then
            local heal_amount = 0
            local cure = 0
            local abilities = wml.get_child(u.__cfg, "abilities") or {}
            for ability in wml.child_range(abilities, "heals") do
                heal_amount = ability.value or 0
                if ability.poison == "slowed" then
                    cure = 1
                elseif ability.poison == "cured" then
                    cure = 2
                end
            end
            if heal_amount + cure > 0 then
                for x, y in H.adjacent_tiles(u.x, u.y) do
                    local old_values = healing_locs:get(x, y) or {0, 0}
                    local best_heal = math.max(old_values[0] or heal_amount)
                    local best_cure = math.max(old_values[1] or cure)
                    healing_locs:insert(x, y, {best_heal, best_cure})
                end
            end
        end
    end

    return healing_locs
end

local function get_retreat_space_units(healees, regen_amounts, avoid_map)
    --for _,h in ipairs(healees) do std_print('healee: ' .. UTLS.unit_str(h)) end

    -- Allies are all ships that can provide protection, as well as all planets
    -- that provide healing
    local allies = AH.get_live_units {
        { "filter_side", { { "allied_with", { side = wesnoth.current.side } } } },
        { 'and', {
            role = 'ship',
            { 'not', { ability = 'transport'} },
            { 'or', { role = 'planet', ability_type = 'heals' } }
        } }
    }
    --for _,a in ipairs(allies) do std_print('ally: ' .. UTLS.unit_str(a)) end
    local healing_locs = get_healing_locations(allies)

    -- These operations are somewhat expensive, don't do them if not necessary
    local enemy_attack_map, ally_attack_map
    if (retreat_enemy_weight ~= 0) then
        -- Just consider non-transport ships for this; that is not entirely accurate,
        -- but neither is the calculation itself, so this should be good enough
        local enemies = AH.get_attackable_enemies {
            role = 'ship',
            { 'not', { ability = 'transport'} }
        }
        enemy_attack_map = BC.get_attack_map(enemies)
        ally_attack_map = BC.get_attack_map(allies)
    end

    local max_rating, best_loc, best_unit = - math.huge
    for i,u in ipairs(healees) do
        local possible_locations = wesnoth.paths.find_reach(u)
        -- TODO: avoid ally's villages (may be preferable to lower rating so they will
        -- be used if unit is very injured)
        if (not regen_amounts[i]) then
            -- Unit cannot self heal, make the terrain do it for us if possible
            local location_subset = {}
            for j,loc in ipairs(possible_locations) do
                if (not avoid_map) or (not avoid_map:get(loc[1], loc[2])) then
                    local heal_amount = wesnoth.terrain_types[wesnoth.current.map[loc]].healing or 0
                    if heal_amount == true then
                        -- handle deprecated syntax
                        -- TODO: remove this when removed from game
                        heal_amount = 8
                    end
                    local curing = 0
                    if heal_amount > 0 then
                        curing = 2
                    end
                    local healer_values = healing_locs:get(loc[1], loc[2]) or {0, 0}
                    heal_amount = math.max(heal_amount, healer_values[1])
                    curing = math.max(curing, healer_values[2])
                    table.insert(location_subset, {loc[1], loc[2], heal_amount, curing})
                end
            end

            possible_locations = location_subset
        end

        local is_healthy = false
        for _,trait in ipairs(u.traits) do
            if (trait == 'healthy') then
                is_healthy = true
                break
            end
        end

        local base_rating = - u.hitpoints + u.max_hitpoints / 2.
        if u.status.poisoned then base_rating = base_rating + wesnoth.game_config.poison_amount end
        if u.status.slowed then base_rating = base_rating + 4 end
        base_rating = base_rating * 1000

        print_dbg(string.format('check retreat hexes for: %-20s  base_rating = %f8.1', u.id, base_rating))

        for j,loc in ipairs(possible_locations) do
            local unit_in_way = wesnoth.units.get(loc[1], loc[2])
            if (not AH.is_visible_unit(wesnoth.current.side, unit_in_way))
                or ((unit_in_way.moves > 0) and (unit_in_way.side == wesnoth.current.side))
            then
                local heal_score = 0
                if regen_amounts[i] then
                    heal_score = math.min(regen_amounts[i], u.max_hitpoints - u.hitpoints)
                else
                    if u.status.poisoned then
                        if loc[4] > 0 then
                            heal_score = math.min(wesnoth.game_config.poison_amount, u.hitpoints - 1)
                            if loc[4] == 2 then
                                -- This value is arbitrary, it just represents the ability to heal on the turn after
                                heal_score = heal_score + 1
                            end
                        end
                    else
                        heal_score = math.min(loc[3], u.max_hitpoints - u.hitpoints)
                    end
                end

                -- Figure out the enemy threat - this is also needed to assess whether rest healing is likely
                local enemy_rating, enemy_count = 0, 0
                if (retreat_enemy_weight ~= 0) then
                    enemy_count = enemy_attack_map.units:get(loc[1], loc[2]) or 0
                    local enemy_hp = enemy_attack_map.hitpoints:get(loc[1], loc[2]) or 0
                    local ally_hp = ally_attack_map.hitpoints:get(loc[1], loc[2]) or 0
                    local hp_diff = ally_hp - enemy_hp * math.abs(retreat_enemy_weight)
                    if (hp_diff > 0) then hp_diff = 0 end

                    -- The rating is mostly the HP difference, but we still want to
                    -- avoid threatened hexes even if we have the advantage
                    enemy_rating = hp_diff - enemy_count * math.abs(retreat_enemy_weight)
                end

                if (loc[1] == u.x) and (loc[2] == u.y) and (not u.status.poisoned) then
                    if is_healthy or enemy_count == 0 then
                        -- Bonus if we can rest heal
                        heal_score = heal_score + wesnoth.game_config.rest_heal_amount
                    end
                end

                -- Only consider healing locations, except when retreat_enemy_weight is negative
                if (heal_score > 0) or (retreat_enemy_weight < 0) then
                    local rating = base_rating + heal_score^2
                    rating = rating + enemy_rating

                    -- Penalty based on terrain defense for unit
                    rating = rating - (100 - u:defense_on(wesnoth.current.map[loc]))/10

                    -- Penalty if a unit has to move out of the way
                    -- (based on hp of moving unit)
                    if unit_in_way and ((loc[1] ~= u.x) or (loc[2] ~= u.y)) then
                        rating = rating + unit_in_way.hitpoints - unit_in_way.max_hitpoints
                    end

                    print_dbg(string.format('  possible retreat hex: %3d,%-3d  rating = %9.1f  (heal_score = %5.1f, enemy_rating = %9.1f)', loc[1], loc[2], rating, heal_score, enemy_rating))

                    if (rating > max_rating) then
                        max_rating, best_loc, best_unit = rating, loc, u
                    end
                end
            end
        end
    end

    local threat = 0
    if best_unit then
        threat = enemy_attack_map and enemy_attack_map.units:get(best_loc[1], best_loc[2]) or 0
        print_dbg(string.format('found unit to retreat: %s --> %d,%d', best_unit.id, best_loc[1], best_loc[2]))
    end

    return best_unit, best_loc, threat
end

-- Given a set of units, return one from the set that should retreat and the location to retreat to
-- Return nil if no unit needs to retreat
local function retreat_space_units(units, avoid_map)
    -- Split units into those that regenerate and those that do not
    local regen, regen_amounts, non_regen = {}, {}, {}
    for i,u in ipairs(units) do
        if (u.hitpoints < min_hp(u)) then
            if u:ability('regenerate') then
                -- Find the best regeneration ability and use it to estimate hp regained by regeneration
                local abilities = wml.get_child(u.__cfg, "abilities")
                local regen_amount = 0
                if abilities then
                    for regen in wml.child_range(abilities, "regenerate") do
                        if regen.value > regen_amount then
                            regen_amount = regen.value
                        end
                    end
                end
                table.insert(regen, u)
                table.insert(regen_amounts, regen_amount)
            else
                table.insert(non_regen, u)
            end
        end
    end

    -- First we retreat non-regenerating units to healing terrain, if they can get to a safe location
    local unit_nr, loc_nr, threat_nr
    if non_regen[1] then
        unit_nr, loc_nr, threat_nr = get_retreat_space_units(non_regen, {}, avoid_map)
        if unit_nr and (threat_nr == 0) then
            return unit_nr, loc_nr, threat_nr
        end
    end

    -- Then we retreat regenerating units to terrain with high defense, if they can get to a safe location
    local unit_r, loc_r, threat_r
    if regen[1] then
        unit_r, loc_r, threat_r = get_retreat_space_units(regen, regen_amounts, avoid_map)
        if unit_r and (threat_r == 0) then
            return unit_r, loc_r, threat_r
        end
    end

    -- The we retreat those that cannot get to a safe location (non-regenerating units first again)
    if unit_nr then
        return unit_nr, loc_nr, threat_nr
    end
    if unit_r then
        return unit_r, loc_r, threat_r
    end
end


local retreat_unit, retreat_loc
local ca_GE_retreat_space = {}

function ca_GE_retreat_space:evaluation(cfg, data, ai_debug)
    local ai = ai or ai_debug

    local ca_score = CFG.get_cfg_parm('CA_scores')[ca_name]
    local ca_score_low = CFG.get_cfg_parm('CA_scores')[ca_name .. '_low']
    if (ca_score < 0) or data.GEAI_abort then return 0 end

    local start_time = wesnoth.ms_since_init() / 1000.
    DBG.print_debug_eval(ca_name, 0, start_time, 'begin eval')


    retreat_unit, retreat_loc= nil, nil

    local units = UTLS.get_ships({ side = wesnoth.current.side }, true)
    local unit, loc = retreat_space_units(units)
    if unit then
        retreat_unit = unit
        retreat_loc = loc
        local str = 'retreat ' .. UTLS.unit_str(retreat_unit) .. ' --> ' .. UTLS.loc_str(retreat_loc)

        -- First check if attacks are possible for any ship
        -- If one with > 50% chance of kill is possible, set return_value to lower than combat CA
        local attacks = AH.get_attacks(units)
        for i_a,att in ipairs(attacks) do
            local ship = wesnoth.units.get(att.src.x, att.src.y)
            local target = wesnoth.units.get(att.target.x, att.target.y)
            local att_stats, def_stats = BC.battle_outcome(ship, target, { dst = { att.dst.x, att.dst.y } })
            --std_print(UTLS.unit_str(ship) .. ' -> ' .. UTLS.unit_str(target) .. ' kill chance: ' .. def_stats.hp_chance[0])

            if (def_stats.hp_chance[0] > 0.5) then
                DBG.print_debug_eval(ca_name, ca_score_low, start_time, str .. ' after attacks')
                return ca_score_low
            end
        end
        if AH.print_eval() then AH.done_eval_messages(start_time, ca_name) end
        DBG.print_debug_eval(ca_name, ca_score, start_time, str)
        return ca_score
    end

    DBG.print_debug_eval(ca_name, 0, start_time, 'found no ships to retreat')
    return 0
end

function ca_GE_retreat_space:execution(cfg, data, ai_debug)
    local ai = ai or ai_debug

    local str = 'retreat ' .. UTLS.unit_str(retreat_unit) .. ' --> ' .. UTLS.loc_str(retreat_loc)
    DBG.print_debug_exec(ca_name, str)
    UTLS.output_add_move(str)

    AH.robust_move_and_attack(ai, retreat_unit, retreat_loc)
    retreat_unit = nil
    retreat_loc = nil
end

return ca_GE_retreat_space

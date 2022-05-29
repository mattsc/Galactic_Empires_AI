----- CA: space_combat -----
--
-- Description:
--   Handle combat in space that we do not want to leave to the default AI.
--   Specifically, attacks on:
--   - Planets (except for neutral planets, which are never attacked)
--     These happen before the default combat CA if the attacking ship has
--     an antimatter weapon, or afterward otherwise, but only on planets that
--     are down to <=25% of their maximum hitpoints in the latter case or on
--     enemy homeworlds
--   - Transports without passengers and probes

local ca_name = 'space_combat'

local best_attack
local ca_GE_space_combat = {}

function ca_GE_space_combat:evaluation(cfg, data, ai_debug)
    local ai = ai or ai_debug

    local ca_score = CFG.get_cfg_parm('CA_scores')[ca_name]
    local ca_score_low = CFG.get_cfg_parm('CA_scores')[ca_name .. '_low']
    if (ca_score < 0) or data.GEAI_abort then return 0 end

    local start_time = wesnoth.ms_since_init() / 1000.
    DBG.print_debug_eval(ca_name, 0, start_time, 'begin eval')


    best_attack = nil

    -- First check whether there are ships with antimatter weapons that can attack enemy planets
    local antimatter_ships = AH.get_units_with_attacks {
        side = wesnoth.current.side,
        role = 'ship',
        { 'has_attack', { type = 'antimatter' } }
    }
    --std_print('#antimatter_ships: ' .. #antimatter_ships)

    -- Ships with antimatter weapons are given high priority for attacks on enemy planets, but:
    --   - exclude neutral planets (these are never attacked)
    --   - exclude planets with allied units on them, except if it's the enemy homeworld
    if (#antimatter_ships > 0) then
        local enemy_planet_map = LS.create()
        local enemy_planets = UTLS.get_planets {
            { 'filter_side', {
                { 'enemy_of', {side = wesnoth.current.side } },
                { 'has_unit', { canrecruit = 'yes' } } -- this excludes neutral planets
            } }
        }
        for i_p,planet in ipairs(enemy_planets) do
            local allied_units = UTLS.get_units_on_planet(planet, {
                { "filter_side", { {"allied_with", { side = wesnoth.current.side } } } }
            })
            --std_print('  ' .. UTLS.unit_str(planet) .. ' #allied_units: ' .. #allied_units)
            if (#allied_units == 0)
                or (planet.variables.colonised == 'homeworld')
            then
                enemy_planet_map:insert(planet.x, planet.y, {
                    id = planet.id,
                    index = i_p
                })
            end
        end
        --DBG.dbms(enemy_planet_map.values, false, 'enemy_planet_map')

        -- Find all attacks that these ships can do, and find the best one
        local atts = AH.get_attacks(antimatter_ships, { include_occupied = true })
        --DBG.dbms(atts)

        local max_rating = - math.huge
        local planet_ratings = {}
        for i_a,att in ipairs(atts) do
            local enemy_planet_info = enemy_planet_map:get(att.target.x, att.target.y)
            if (enemy_planet_info) then
                local planet = enemy_planets[enemy_planet_info.index]
                --std_print(i_a .. ' is enemy planet: ' .. UTLS.unit_str(planet))

                -- Rating: damage is the same against all planets and they don't have
                -- weapons, so don't need to consider attacks
                -- Prefer already damaged planets, those with many enemy units on them
                -- and high production and homeworlds
                local rating = 0

                -- A lot of the rating is the same for a given planet, and some of it
                -- (specifically getting the total production) is somewhat slow to
                -- to calculate, so we save and reuse what we can
                if planet_ratings[planet.id] then
                    rating = rating + planet_ratings[planet.id]
                else
                    rating = rating + 2 * (planet.max_hitpoints - planet.hitpoints)
                    --std_print('  base rating: ' .. rating)

                    local enemies = UTLS.get_units_on_planet(planet, {
                        { "filter_side", { {"enemy_of", { side = wesnoth.current.side } } } }
                    })
                    rating = rating + #enemies * 10
                    --std_print('    plus enemy rating: ' .. rating)

                    local total_food, total_gold = UTLS.total_production(planet)
                    rating = rating + (total_food + total_gold)
                    --std_print('    plus production rating: ' .. rating, total_food + total_gold)

                    -- Substantial bonus for the homeworld, but not so much that it overrides everything else
                    if (planet.variables.colonised == 'homeworld') then
                        rating = rating + 100
                    end
                    --std_print('    plus homeworld rating: ' .. rating)

                    planet_ratings[planet.id] = rating
                end
                if att.attack_hex_occupied then
                    rating = rating - 1
                end

                rating = rating + math.random()
                --std_print(planet.id .. ' total rating: ' .. rating, UTLS.loc_str(att.dst))

                if rating > max_rating then
                    max_rating = rating
                    best_attack = att
                end
            end
        end
        --DBG.dbms(best_attack, false, 'best_attack antimatter attacks')

        if best_attack then
            DBG.print_debug_eval(ca_name, ca_score, start_time, 'found antimatter attack on planet')
            return ca_score
        else
            DBG.print_debug_eval(ca_name, 0, start_time, 'no antimatter attack on planet found')
        end
    end


    -- If we got here, no antimatter attacks on planets were found
    -- Check what attacks remain on planets, transports and probes
    --   - exclude neutral planets (these are never attacked)
    --   - exclude planets with allied units on them, except if it's the enemy homeworld
    --   - exclude transports with passengers

    -- Find all other ships that have attacks left
    -- Exclude flagship (handled separately) and transporters (which don't have real weapons)
    local ships = AH.get_units_with_attacks {
        side = wesnoth.current.side,
        role = 'ship',
        { 'not', { ability = 'flagship' } },
        { 'not', { ability = 'transport' } },
    }
    --std_print('#ships: ' .. #ships)
    --for _,ship in ipairs(ships) do std_print(UTLS.unit_str(ship)) end

    if (#ships > 0) then
        local valid_target_map = LS.create()
        local all_enemies = AH.get_attackable_enemies {
            -- Note: there seems to be some bug in get_attackable_enemies()
            -- If the probes are inside an [or] tag, they are visible even if they should not be
            -- So for this to work, we need to place them first here
            type = 'Iildari Probe, Terran Probe',
            { 'or', {
                ability = 'transport',
                { 'has_attack', { name = 'passengers', damage = 0 } }
            } },
            { 'or', {
                role = 'planet',
                { 'filter_side', {  -- this excludes neutral planets
                    { 'has_unit', { canrecruit = 'yes' } }
                } }
            } }
        }
        for i_e,enemy in ipairs(all_enemies) do
            --std_print('enemy: ' .. UTLS.unit_str(enemy))
            if (enemy.role == 'planet') then
                local allied_units = UTLS.get_units_on_planet(enemy, {
                    { "filter_side", { {"allied_with", { side = wesnoth.current.side } } } }
                })
                --std_print('  ' .. UTLS.unit_str(enemy) .. ' #allied_units: ' .. #allied_units)

                -- Without antimatter weapons, attacks on planets are generally a waste of
                -- firepower -> do them only if planet is down to 25% of its max hitpoints
                -- or if this is an enemy homeworld
                if ((enemy.hitpoints <= 0.25 * enemy.max_hitpoints) and (#allied_units == 0))
                    or (enemy.variables.colonised == 'homeworld')
                then
                    valid_target_map:insert(enemy.x, enemy.y, {
                        id = enemy.id,
                        type = 'planet',
                        index = i_e
                    })
                end
            elseif (enemy.type == 'Iildari Probe') or (enemy.type == 'Terran Probe') then
                valid_target_map:insert(enemy.x, enemy.y, {
                    id = enemy.id,
                    type = 'probe',
                    index = i_e
                })
            else
                valid_target_map:insert(enemy.x, enemy.y, {
                    id = enemy.id,
                    type = 'transport',
                   index = i_e
                })
            end
        end
        --DBG.dbms(valid_target_map.values, false, 'valid_target_map')

        -- Find all attacks that these ships can do, and find the best one
        local atts = AH.get_attacks(ships, { include_occupied = true })
        --DBG.dbms(atts)

        local max_rating = - math.huge
        local ratings = {}
        for i_a,att in ipairs(atts) do
            local target_info = valid_target_map:get(att.target.x, att.target.y)
            if (target_info) then
                local ship = wesnoth.units.get(att.src.x, att.src.y)
                local target = all_enemies[target_info.index]

                local rating = BC.attack_rating(ship, target, { att.dst.x, att.dst.y })

                -- Prefer attacks on transports over probes over planets
                if (target_info.type == 'transport') then
                    rating = rating + 2000
                elseif (target_info.type == 'probe') then
                    rating = rating + 1000
                end

                rating = rating + math.random() / 100

                --std_print(i_a .. ': ' .. UTLS.unit_str(ship) .. ' --> ' .. UTLS.unit_str(target) .. ' from ' .. UTLS.loc_str(att.dst) .. ': ' .. rating)
                --std_print(' total rating: ' .. rating, UTLS.loc_str(att.dst))
                if rating > max_rating then
                    max_rating = rating
                    best_attack = att
                end
            end
        end
        --DBG.dbms(best_attack, false, 'best_attack other attacks')
    end

    if best_attack then
        DBG.print_debug_eval(ca_name, ca_score, start_time, 'found attack')
        -- This one returns the low score
        return ca_score_low
    end

    DBG.print_debug_eval(ca_name, 0, start_time, 'no other attack found')
    return 0
end

function ca_GE_space_combat:execution(cfg, data, ai_debug)
    local ai = ai or ai_debug

    -- Only needed for output, could just pass src and target to robust_move_and_attack
    local unit = wesnoth.units.get(best_attack.src.x, best_attack.src.y)
    local enemy = wesnoth.units.get(best_attack.target.x, best_attack.target.y)

    local str = 'attack: ' .. UTLS.unit_str(unit) .. ' --> ' .. UTLS.unit_str(enemy) .. ' from ' .. UTLS.loc_str(best_attack.dst)
    DBG.print_debug_exec(ca_name, str)
    UTLS.output_add_move(str)

    AH.robust_move_and_attack(ai, best_attack.src, best_attack.dst, best_attack.target)

    best_attack = nil
end

return ca_GE_space_combat

----- CA: move_to_enemy -----
--
-- Description:
--   Move units on the ground and in space toward enemies
--   This should only apply to enemies out of range, as others should have been attacked already

local ca_name = 'move_to_enemy'

local function find_best_move(unit_ratings, enemies, unit_move)
    for _,unit_rating in ipairs(unit_ratings) do
        local unit = wesnoth.units.find_on_map { id = unit_rating.id }[1]

        -- Full path finding of all units to all enemies can be expensive
        -- --> sort enemies by distance first, and move toward the closest enemy
        -- to which a move is possible
        local enemy_distances = {}
        for i_e,enemy in ipairs(enemies) do
            local dist = wesnoth.map.distance_between(unit, enemy)
            table.insert(enemy_distances, { id = enemy.id, dist = dist, index = i_e })
        end
        table.sort(enemy_distances, function(a, b) return a.dist < b.dist end)
        --DBG.dbms(enemy_distances, false, 'enemy_distances')

        for _,enemy_distance in ipairs(enemy_distances) do
            local enemy = enemies[enemy_distance.index]
            local min_cost, closest_hex = math.huge
            for xa,ya in H.adjacent_tiles(enemy.x, enemy.y) do
                local _,cost = wesnoth.paths.find_path(unit, xa, ya)
                if (cost < 99) and (cost < min_cost) then
                    min_cost = cost
                    closest_hex = { xa, ya }
                end
            end
            --std_print(UTLS.unit_str(enemy), min_cost, closest_hex and closest_hex[1], closest_hex and closest_hex[2])

            if closest_hex then
                local next_hop = AH.next_hop(unit, closest_hex[1], closest_hex[2])
                --std_print('next_hop', UTLS.loc_str(next_hop))
                if (next_hop[1] ~= unit.x) or (next_hop[2] ~= unit.y) then
                    unit_move[unit.id] = next_hop
                    --DBG.dbms(unit_move, false, 'unit_move')
                    return  -- as soon as a viable move is found, we return it
                end
            end
        end
    end
end

local unit_move
local ca_GE_move_to_enemy = {}

function ca_GE_move_to_enemy:evaluation(cfg, data)
    local ca_score = CFG.get_cfg_parm('CA_scores')[ca_name]
    if (ca_score < 0) or data.GEAI_abort then return 0 end

    local start_time = wesnoth.ms_since_init() / 1000.
    DBG.print_debug_eval(ca_name, 0, start_time, 'begin eval')


    unit_move = {}

    -- Consider units on the ground first
    -- Find all planets with own and enemy units on them
    local all_planets = UTLS.get_planets()
    --std_print('#all_planets: ' .. #all_planets)
    local all_units = wesnoth.units.find_on_map()
    --std_print('#all_units: ' .. #all_units)

    for _,planet in ipairs(all_planets) do
        local unit_ratings, enemies_this_planet = {}, {}
        for i_u,unit in ipairs(all_units) do
            if (unit.role == planet.id) then
                if wesnoth.sides.is_enemy(unit.side, wesnoth.current.side) then
                    table.insert(enemies_this_planet, unit)
                elseif (unit.side == wesnoth.current.side)
                    and (unit.moves > 0)
                    and (not unit:matches { has_weapon = 'food' })
                then
                    -- Best unit is the one with the most power, with moves left as a minor rating
                    local rating = UTLS.unit_power(unit) + unit.moves
                    table.insert(unit_ratings, { id = unit.id, rating = rating })
                end
            end
        end
        table.sort(unit_ratings, function(a, b) return a.rating > b.rating end)

        --DBG.print_debug_eval(ca_name, -1, start_time, planet.id, #unit_ratings, #enemies_this_planet)

        if (#enemies_this_planet > 0) and (#unit_ratings > 0) then
            --DBG.dbms(unit_ratings, false, 'unit_ratings')
            find_best_move(unit_ratings, enemies_this_planet, unit_move)
            if next(unit_move) then
                DBG.print_debug_eval(ca_name, ca_score, start_time, 'found ground unit to be moved')
                return ca_score
            end
        end
    end

    DBG.print_debug_eval(ca_name, 0, start_time, 'no ground unit found to be moved')


    -- Now look at combat ships; flagships are treated like normal ships in this context
    local ships = UTLS.get_ships {
        side = wesnoth.current.side,
        { 'not', { ability = 'transport'} }
    }
    --for _,ship in ipairs(ships) do std_print(UTLS.unit_str(ship)) end

    -- Enemies to move toward are any non-petrified enemy ship,
    -- or all planets with a spacedock
    -- Cannot use AH.get_attackable_enemies here, as visibility is also checked in that function
    -- and that might render the AI passive
    local enemies = wesnoth.units.find_on_map {
        { 'not', { status = 'petrified' } },
        { 'filter_side', { { 'enemy_of', {side = wesnoth.current.side } } } },
        { 'and', {
            role = 'ship',
            { 'or', { ability = 'spacedock' } }
        } }
    }
    --for _,enemy in ipairs(enemies) do std_print(UTLS.unit_str(enemy)) end

    local ship_ratings = {}
    for _,ship in ipairs(ships) do
        if (ship.moves > 0) then
            local rating = UTLS.unit_power(ship) + ship.moves
            table.insert(ship_ratings, { id = ship.id, rating = rating })
        end
    end
    table.sort(ship_ratings, function(a, b) return a.rating > b.rating end)
    --DBG.dbms(ship_ratings, false, 'ship_ratings')

    -- in order to avoid conflicts, we move one unit at a time
    -- it's a bit inefficient, but none of this takes much computation time
    for _,ship_rating in ipairs(ship_ratings) do
        find_best_move(ship_ratings, enemies, unit_move)
        if next(unit_move) then
            DBG.print_debug_eval(ca_name, ca_score, start_time, 'found ship to be moved')
            return ca_score
        end
    end

    DBG.print_debug_eval(ca_name, 0, start_time, 'no qualifying moves found')
    return 0
end

function ca_GE_move_to_enemy:execution(cfg, data, ai_debug)
    local ai = ai or ai_debug

    local unit_id, dst = next(unit_move)
    local unit = wesnoth.units.find_on_map { id = unit_id }[1]

    local str = 'move ' .. UTLS.unit_str(unit) .. '  -->  ' .. UTLS.loc_str(dst)
    DBG.print_debug_exec(ca_name, str)
    UTLS.output_add_move(str)

    AH.robust_move_and_attack(ai, unit, dst) -- full move only

    unit_move = {}
end

return ca_GE_move_to_enemy

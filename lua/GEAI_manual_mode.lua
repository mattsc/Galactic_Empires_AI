--------------------------------------------------------------------------------
local show_menu_item = false        -- should generally be set to false, enable for AI debug testing only
local show_extra_menu_items = false  -- should generally be set to false, enable for AI debug testing only
local ca_name = 'transport_troops'
--local ca_name = 'research'
--local ca_name = 'move_ground'
--local ca_name = 'move_to_enemy'
--local ca_name = 'population_control'
--local ca_name = 'claim_artifact'
--local ca_name = 'upgrade'
--local ca_name = 'reset_vars'
--local ca_name = 'recruit'
--local ca_name = 'retreat_space'
--local ca_name = 'space_combat'
--local ca_name = 'flagship'
--local ca_name = 'ground_combat'
--------------------------------------------------------------------------------

local GEAI_manual_mode = {}

function GEAI_manual_mode.show_menu_item()
    -- Requires both debug mode and 'show_menu_item = true' (above) for menu item to be shown
    if wesnoth.game_config.debug then return show_menu_item end
    return false
end

function GEAI_manual_mode.show_extra_menu_items()
    -- Requires both debug mode and 'show_extra_menu_items = true' (above) for menu item to be shown
    if wesnoth.game_config.debug then return show_extra_menu_items end
    return false
end

function GEAI_manual_mode.manual_mode()
    -- Turn fog/shroud off in manual testing mode
    wesnoth.wml_actions.modify_side {
        fog = false,
        shroud = false
    }

    wesnoth.interface.clear_chat_messages()
    local ca_score = CFG.get_cfg_parm('CA_scores')[ca_name]
    std_print('\n---------- Manual move: ' .. ca_name .. ' (' .. ca_score .. ') ----------')
    if (ca_score <= 0) then
        wesnoth.interface.add_chat_message('manual mode warning', '***** CA score is set to ' .. ca_score .. ' in config *****')
    end

    local ai_debug = wesnoth.sides.debug_ai(wesnoth.current.side).ai
    local ca = wesnoth.dofile('~add-ons/Galactic_Empires_AI/lua/ca_GE_' .. ca_name .. '.lua')
    local score = ca:evaluation(dummy_cfg, dummy_data, ai_debug)
    wesnoth.interface.add_chat_message('manual mode', ca_name .. ' score: ' .. score)
    if (score > 0) then ca:execution(dummy_cfg, dummy_data, ai_debug) end
end

function GEAI_manual_mode.add_research_points()
    local var = 'empire[' .. wesnoth.current.side .. '].research_points'
    wml.variables[var] = wml.variables[var] + 30
end

function GEAI_manual_mode.units_info(stdout_only)
    -- Show information for all units. Specifically, this links the
    -- unit id to its position, name etc. for easier identification.
    -- It also puts labels with the unit ids on the map. A second call
    -- to the function removes the labels.
    local tmp_unit_proxies = wesnoth.units.find_on_map()
    local str = ''
    for _,u in ipairs(tmp_unit_proxies) do
        str = str .. string.format('%2d,%2d    HP: %3d/%3d    XP: %3d/%3d   pow: %5.1f        %s      (%s)\n',
        u.x, u.y,
        u.hitpoints, u.max_hitpoints, u.experience, u.max_experience, UTLS.unit_power(u),
        u.id, tostring(u.name))

        if wml.variables.debug_unit_labels then
            wesnoth.label { x = u.x, y = u.y, text = '' }
        else
            wesnoth.label { x = u.x, y = u.y, text = u.id }
        end
    end

    if wml.variables.debug_unit_labels then
        wml.variables.debug_unit_labels = nil
        wesnoth.clear_messages()
    else
        wml.variables.debug_unit_labels = true
        std_print(str)
        --if (not stdout_only) then wesnoth.message(str) end

        local transports = UTLS.get_transports { side = wesnoth.current.side }
        local str2 = ''
        for _,transport in pairs(transports) do
            if transport.variables.GEAI_purpose then
                local str1 = UTLS.unit_str(transport)
                str1 = str1 .. '  ' .. transport.variables.GEAI_purpose ..':'
                str1 = str1 .. ' ' .. transport.variables.GEAI_goal_id
                if transport.variables.GEAI_pickup_id then
                    str1 = str1 .. ' via ' .. transport.variables.GEAI_pickup_id
                end
                std_print(str1)
            else
                str2 = str2 .. '\n' .. UTLS.unit_str(transport)
            end

            local passengers = wml.array_access.get('passengers', transport)
            for _,passenger in ipairs(passengers) do
                local unit = wesnoth.units.find_on_recall { id = passenger.id }[1]
                std_print('  passenger: ' .. passenger.type .. '  HP: ' .. passenger.hp .. '/' .. passenger.max_hp .. '  power: ' .. UTLS.unit_power(unit))
            end
        end
        std_print(str2)
    end
end

return GEAI_manual_mode

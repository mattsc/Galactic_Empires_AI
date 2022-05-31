-- Set up the custom synced commands for the AI

function wesnoth.custom_synced_commands.GEAI_reset_moves(cfg)
    local unit = wesnoth.units.find_on_map { id = cfg.id }[1]
    unit.moves = cfg.moves
end

function wesnoth.custom_synced_commands.GEAI_beam_up(cfg)
    wesnoth.fire_event_by_id('Beam_Up_' .. cfg.direction, cfg.x, cfg.y)
end

function wesnoth.custom_synced_commands.GEAI_beam_down(cfg)
    wesnoth.wml_actions.store_unit {
        { 'filter', { id = cfg.transport_id } },
        variable = 'ship'
    }
    wesnoth.wml_actions.store_unit {
        { 'filter', { id = cfg.planet_id } },
        variable = 'planet'
    }
    wml.variables.GE_i_pass = cfg.index - 1 -- difference between WML and Lua indexing

    wesnoth.fire_event('beam_down')

    wml.variables.ship = nil
    wml.variables.planet = nil
    wml.variables.GE_i_pass = nil
end

function wesnoth.custom_synced_commands.GEAI_buy_upgrade(cfg)
    wesnoth.fire_event('upgrade_' .. cfg.utype, cfg.x, cfg.y)
end

function wesnoth.custom_synced_commands.GEAI_population_control(cfg)
    wml.variables.new_hq_unit = cfg.unit_type
    wesnoth.fire_event('set_population_control', cfg.x, cfg.y)
    wml.variables.new_hq_unit = nil
end

function wesnoth.custom_synced_commands.GEAI_set_variable(cfg)
    wml.variables[cfg.name] = cfg.value
end

function wesnoth.custom_synced_commands.GEAI_set_unit_variable(cfg)
    local unit = wesnoth.units.find_on_map { id = cfg.id }[1]
    unit.variables[cfg.name] = cfg.value
end

function wesnoth.custom_synced_commands.GEAI_allow_recruit(cfg)
    wesnoth.wml_actions.allow_recruit { side = cfg.side, type = cfg.type }
end

----- CA: reset_vars -----
--
-- Description:
--   Reset variables at the beginning of each turn

local ca_name = 'reset_vars'

local ca_GE_reset_vars = {}

function ca_GE_reset_vars:evaluation()
    local ca_score = CFG.get_cfg_parm('CA_scores')[ca_name]
    -- This will result in blacklisting, so that it is executed exactly once per turn
    return ca_score
end

function ca_GE_reset_vars:execution(cfg, data)
    -- Debug use only: set controller to 'human' at beginning of turn.
    -- This can be used to get control of a game saved from a replay for trouble shooting.
    if false then
        wesnoth.sides[wesnoth.current.side].controller = 'human'
        UTLS.force_gamestate_change(ai)
    end

    --DBG.dbms(data, false, 'data before')
    UTLS.reset_vars(data)
    --DBG.dbms(data, false, 'data after')
end

return ca_GE_reset_vars

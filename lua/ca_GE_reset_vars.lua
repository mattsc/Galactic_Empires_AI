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
    --DBG.dbms(data, false, 'data before')
    UTLS.reset_vars(data)
    --DBG.dbms(data, false, 'data after')
end

return ca_GE_reset_vars

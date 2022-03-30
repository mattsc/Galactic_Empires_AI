-- AI configuration parameters

-- Note: Assigning this table is slow compared to accessing values in it. It is
-- thus done outside the functions below, so that it is not done over and over
-- for each function call.

local GEAI_cfg = {
    CA_scores = {
        -- setting a rating to negative values disables the action
        -- setting it to zero can be used to run the evaluation only
        reset_vars =         900000,
        research =           640000,
        claim_artifact =     620000,
        upgrade =            600000,  -- upgrades to planets and HQs
        retreat_space =      500000,
        flagship =           420000,  -- flagship attacks
        upgrade_flagship =   410000,  -- flagship upgrades
        flagship_move =      400000,  -- flagship moves
        space_combat =       310000,
        --combat =           300000,  -- handled by default AI
        ground_combat =      280000,  -- attacks on aliens
        retreat_space_low =  270000,  -- if to be executed after attacks
        upgrade_ship =       260000,  -- upgrades to ships other than the flagship
        transport_troops =   120000,
        recruit =            100000,
        space_combat_low =    80000,  -- attacks on planets without antimatter attacks
        move_to_enemy =       60000,
        move_ground =         40000,
        population_control =  20000
    },

    -- food_value: value of food production in gold units. The AI tries to arrange
    -- workers on planets according to this ratio. For example, if this is set to 2,
    -- the AI tries to produce approximately twice as much food as gold.
    -- Set this to negative values if you want to maximize total production,
    -- irrespective of whether it is food or gold.
    -- Note: Using multiples of 0.5 sometimes results in shuffling back and forth of the workers.
    --    This can be avoided by setting food_value to, say, 1.01 instead of 1.00.
    food_value = 1.51,

    -- Relative priorities with which HQs should produce the different types of units.
    -- This is evaluated on a planet-by-planet basis, not for the overall population.
    population_priorities = {
        Dwartha = {
            work_unit = 3.1,
            science_unit = 1,
            combat_unit =  1
        },
        Iildari = {
            work_unit = 3.1,
            science_unit = 1.4,
            combat_unit =  1
        },
        Terran = {
            work_unit = 2.9,
            science_unit = 1.2,
            combat_unit =  1
        },
        Vendeeni = {
            work_unit = 3.1,
            science_unit = 1,
            combat_unit =  1.4
        }
    },

    -- Relative priorities by which to weight advancing of the research fields.
    -- There are three different regimes how this can be used:
    -- 1. Priorities are set to different non-zero values: both current levels and priorities
    --    are taken into account when determining which field to advance next, with fields that
    --    are at low levels and having high priorities being preferred
    -- 2. Priorities are set to identical non-zero values: choice between the fields is
    --    random, except that fields with the lowest current levels are advanced first. In other
    --    words, all fields are advanced from tier 0 to 1 first, then from 1 to 2, etc.
    -- 3. Priorities are all set to zero: the choice of the field to advance next is fully random
    --    and irrespective of how far advanced each field is already
    research_priorities = {
        gadgets = 1,
        hq = 1,
        planet = 1,
        ships = 1.2
    },

    -- Upgrades:
    -- Do not spend more than this fraction of the turn starting gold on upgrades:
    upgrade_gold_fraction = 0.25,
    -- Do not buy upgrade if gold remaining after is less than:
    upgrade_gold_remaining = 30,
    -- Do not install upgrades before this turn:
    upgrade_first_turn = 2
}

local GEAI_config = {}

function GEAI_config.get_cfg_parm(parm)
    return GEAI_cfg[parm]
end

return GEAI_config

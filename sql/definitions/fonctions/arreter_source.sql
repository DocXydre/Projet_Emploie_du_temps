CREATE OR REPLACE FUNCTION arreter_source(p_code VARCHAR) RETURNS JSONB
LANGUAGE plpgsql AS $$
DECLARE
    v_source   RECORD;
    v_retirees INTEGER;
BEGIN
    SELECT * INTO v_source FROM source WHERE code = upper(p_code);
    IF NOT FOUND THEN
        RETURN NULL;
    END IF;

    -- L'URL est gardée : reprendre la source ne demandera que /lien. Une
    -- source inactive n'est ni collectée, ni signalée en panne dans le bilan
    -- du matin.
    UPDATE source SET active = FALSE WHERE id_source = v_source.id_source;

    -- COL-21 : seul l'avenir disparaît. Un service en cours a lieu, il reste.
    DELETE FROM occupation
     WHERE id_source = v_source.id_source
       AND lower(periode) > now();
    GET DIAGNOSTICS v_retirees = ROW_COUNT;

    RETURN jsonb_build_object('source',               v_source.code,
                              'occupations_retirees', v_retirees);
END $$;

COMMENT ON FUNCTION arreter_source IS
    'Cesse de suivre une source : elle n''est plus collectée, ses occupations à
     venir sont retirées, les passées restent (COL-21).';

CREATE OR REPLACE FUNCTION tracer_coach(p_utilisateur INTEGER, p_type TEXT,
                                        p_id BIGINT DEFAULT NULL,
                                        p_detail JSONB DEFAULT '{}')
RETURNS VOID LANGUAGE sql AS $$
    INSERT INTO trace_coach (operation, id_utilisateur, type, id_objet, detail)
    VALUES (COALESCE(NULLIF(current_setting('planif.operation', TRUE), ''),
                     'tx' || txid_current()),
            p_utilisateur, p_type, p_id, COALESCE(p_detail, '{}'));
$$;

COMMENT ON FUNCTION tracer_coach(INTEGER, TEXT, BIGINT, JSONB) IS
    'COA-18 : note ce que l''opération en cours vient d''écrire. C''est de là
     que viennent les éléments d''une réponse du coach.';

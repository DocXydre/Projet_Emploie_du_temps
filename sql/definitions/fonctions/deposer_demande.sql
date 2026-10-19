-- -----------------------------------------------------------------------------
-- Déposer une demande, déjà essayée                                 (ACC-1 à ACC-3)
--
-- L'API a joué l'action dans une transaction annulée : la base l'accepterait.
-- La demande attend l'accord de l'utilisateur, 48 heures au plus (ACC-8), ou
-- moins si ce qu'elle vise est plus proche. Déposée par HAL dans l'appli, elle
-- devient un élément de sa réponse (COA-18), par la trace de l'opération.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION deposer_demande(
    p_utilisateur INTEGER,
    p_action      TEXT,
    p_parametres  JSONB,
    p_resume      TEXT,
    p_motif       TEXT,
    p_client      TEXT        DEFAULT NULL,
    p_id_session  UUID        DEFAULT NULL,
    p_echeance    TIMESTAMPTZ DEFAULT NULL
) RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE
    v_operation TEXT := COALESCE(NULLIF(current_setting('planif.operation', TRUE), ''),
                                 'tx' || txid_current());
    v_appel     BIGINT;
    v_id        BIGINT;
BEGIN
    IF btrim(COALESCE(p_motif, '')) = '' THEN
        PERFORM refus_coach('requete_invalide',
            'Une demande dit pourquoi, en une phrase : « motif » est vide.');
    END IF;
    IF p_client IS NULL THEN
        SELECT a.id_appel INTO v_appel FROM appel_coach a
         WHERE a.operation = v_operation AND a.statut = 'en_cours'
         ORDER BY a.id_appel DESC LIMIT 1;
    END IF;

    INSERT INTO demande (id_utilisateur, action, parametres, resume, motif, origine, client,
                         id_appel, id_session, operation, expire_le)
    VALUES (p_utilisateur, p_action, COALESCE(p_parametres, '{}'), p_resume,
            left(btrim(p_motif), 300),
            CASE WHEN p_client IS NULL THEN 'HAL' ELSE 'client' END, left(p_client, 60),
            v_appel, p_id_session, v_operation,
            -- Au plus 48 h, au moins une heure : ce qui vise plus tôt expire avec.
            GREATEST(LEAST(now() + INTERVAL '48 hours',
                           COALESCE(p_echeance, now() + INTERVAL '48 hours')),
                     now() + INTERVAL '1 hour'))
    RETURNING id_demande INTO v_id;

    PERFORM tracer_coach(p_utilisateur, 'demande', v_id,
                         jsonb_build_object('action', p_action));
    RETURN v_id;
END $$;

COMMENT ON FUNCTION deposer_demande(INTEGER, TEXT, JSONB, TEXT, TEXT, TEXT, UUID, TIMESTAMPTZ) IS
    'ACC-1 à ACC-3 : garde une demande déjà essayée, en attente de l''accord de
     l''utilisateur, et la note dans la trace de l''opération.';

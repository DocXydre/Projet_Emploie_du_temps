-- -----------------------------------------------------------------------------
-- Noter une soirée                                          (SOI-1, SOI-2, SOI-4)
--
-- Une par nuit et par compte. Repérée à minuit, elle est « probable » ; dite
-- ou racontée, elle garde ce qu'on en a dit. Ce qui n'est pas donné ne remplace
-- pas ce qui l'était déjà. « Écartée » : ce n'était pas une soirée.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION noter_soiree(
    p_utilisateur INTEGER,
    p_nuit        DATE,
    p_origine     VARCHAR,
    p_statut      VARCHAR,
    p_verres      SMALLINT DEFAULT NULL,
    p_couche_a    TIMESTAMPTZ DEFAULT NULL,
    p_ressenti    SMALLINT DEFAULT NULL,
    p_commentaire TEXT DEFAULT NULL
) RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE
    v_id BIGINT;
BEGIN
    IF p_nuit IS NULL OR p_nuit > jour_de(now()) OR p_nuit < jour_de(now()) - 14 THEN
        PERFORM refus_coach('requete_invalide',
            'Une soirée se note pour ce soir ou l''une des quatorze nuits passées');
    END IF;
    INSERT INTO soiree AS s (id_utilisateur, nuit, origine, statut, verres, couche_a,
                             ressenti, commentaire, racontee_le)
    VALUES (p_utilisateur, p_nuit, p_origine, p_statut, p_verres, p_couche_a, p_ressenti,
            NULLIF(btrim(p_commentaire), ''),
            CASE WHEN p_statut IN ('racontee', 'ecartee') THEN now() END)
    ON CONFLICT (id_utilisateur, nuit) DO UPDATE
       SET statut      = CASE WHEN EXCLUDED.statut = 'probable' THEN s.statut
                              ELSE EXCLUDED.statut END,
           verres      = COALESCE(EXCLUDED.verres, s.verres),
           couche_a    = COALESCE(EXCLUDED.couche_a, s.couche_a),
           ressenti    = COALESCE(EXCLUDED.ressenti, s.ressenti),
           commentaire = COALESCE(EXCLUDED.commentaire, s.commentaire),
           racontee_le = COALESCE(EXCLUDED.racontee_le, s.racontee_le)
    RETURNING id_soiree INTO v_id;
    RETURN v_id;
END $$;

COMMENT ON FUNCTION noter_soiree(INTEGER, DATE, VARCHAR, VARCHAR, SMALLINT, TIMESTAMPTZ,
                                 SMALLINT, TEXT) IS
    'SOI-1, SOI-2, SOI-4 : une soirée par nuit, repérée, dite ou racontée, ou écartée.';

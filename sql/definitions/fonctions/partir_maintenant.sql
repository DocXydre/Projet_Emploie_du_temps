-- -----------------------------------------------------------------------------
-- Déclarer son départ, sans savoir quand on rentre                        (ABS-7)
--
-- Comme pour un aller sans retour, l'absence court jusqu'à la première
-- obligation connue. Elle se termine ensuite avec /retour.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION partir_maintenant(
    p_utilisateur INTEGER,
    p_lieu        VARCHAR DEFAULT NULL,
    p_instant     TIMESTAMPTZ DEFAULT now()
) RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE
    v_fin     TIMESTAMPTZ;
    v_absence INTEGER;
BEGIN
    IF EXISTS (SELECT 1 FROM absence
                WHERE id_utilisateur = p_utilisateur AND periode @> p_instant) THEN
        RAISE EXCEPTION 'Une absence est déjà en cours'
            USING ERRCODE = 'check_violation';
    END IF;

    SELECT f.fin INTO v_fin
      FROM fenetres_de_depart(p_utilisateur,
                              p_instant - INTERVAL '1 minute',
                              p_instant + INTERVAL '30 days',
                              1) f
     ORDER BY f.debut
     LIMIT 1;

    -- Aucune obligation connue dans le mois : on prend deux jours par
    -- défaut, le temps qu'un retour soit déclaré.
    v_fin := COALESCE(v_fin, p_instant + INTERVAL '2 days');

    INSERT INTO absence (id_utilisateur, periode, lieu, origine, commentaire)
    VALUES (p_utilisateur, tstzrange(p_instant, v_fin, '[)'),
            p_lieu, 'manuelle', 'départ déclaré, retour à confirmer')
    RETURNING id_absence INTO v_absence;

    RETURN v_absence;
END $$;

COMMENT ON FUNCTION partir_maintenant IS
    'Ouvre une absence à l''instant présent, jusqu''à la prochaine obligation '
    'connue (ABS-7).';

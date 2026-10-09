CREATE OR REPLACE FUNCTION recevoir_activite(
    p_utilisateur INTEGER,
    p_cle_externe VARCHAR,
    p_type        VARCHAR,
    p_discipline  VARCHAR,
    p_debut       TIMESTAMPTZ,
    p_fin         TIMESTAMPTZ,
    p_donnees     JSONB DEFAULT '{}'
) RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE
    v_activite   BIGINT;
    v_creee      BOOLEAN;
    v_occurrence INTEGER;
    v_duree      INTEGER;
BEGIN
    IF p_fin <= p_debut OR p_fin > now() + INTERVAL '5 minutes' THEN
        PERFORM refus_coach('requete_invalide',
            'Une séance de la montre a un début, une fin, et n''est pas dans le futur');
    END IF;
    v_duree := COALESCE((p_donnees ->> 'duree_secondes')::INTEGER,
                        EXTRACT(EPOCH FROM (p_fin - p_debut))::INTEGER);

    -- SAN-3 : la même clé renvoyée met à jour sans dupliquer. SAN-2 : ce que
    -- les colonnes ne nomment pas est gardé tel quel dans `details`.
    INSERT INTO activite_sante AS ac (id_utilisateur, cle_externe, type, discipline, periode,
                                duree_secondes, distance_m, denivele_m, energie_kcal,
                                fc_moyenne, fc_max, allure_s_km, cadence, details)
    VALUES (p_utilisateur, p_cle_externe, left(p_type, 40), p_discipline,
            tstzrange(p_debut, p_fin, '[)'), GREATEST(v_duree, 1),
            (p_donnees ->> 'distance_m')::INTEGER, (p_donnees ->> 'denivele_m')::INTEGER,
            (p_donnees ->> 'energie_kcal')::INTEGER, (p_donnees ->> 'fc_moyenne')::SMALLINT,
            (p_donnees ->> 'fc_max')::SMALLINT, (p_donnees ->> 'allure_s_km')::SMALLINT,
            (p_donnees ->> 'cadence')::SMALLINT,
            COALESCE(p_donnees -> 'details', '{}'))
    ON CONFLICT (id_utilisateur, cle_externe) DO UPDATE
       SET type = EXCLUDED.type, periode = EXCLUDED.periode,
           duree_secondes = EXCLUDED.duree_secondes,
           distance_m   = COALESCE(EXCLUDED.distance_m, ac.distance_m),
           denivele_m   = COALESCE(EXCLUDED.denivele_m, ac.denivele_m),
           energie_kcal = COALESCE(EXCLUDED.energie_kcal, ac.energie_kcal),
           fc_moyenne   = COALESCE(EXCLUDED.fc_moyenne, ac.fc_moyenne),
           fc_max       = COALESCE(EXCLUDED.fc_max, ac.fc_max),
           allure_s_km  = COALESCE(EXCLUDED.allure_s_km, ac.allure_s_km),
           cadence      = COALESCE(EXCLUDED.cadence, ac.cadence),
           details      = ac.details || EXCLUDED.details,
           recue_le     = now()
    RETURNING ac.id_activite, (xmax = 0) INTO v_activite, v_creee;

    v_occurrence := rattacher_activite(v_activite);
    RETURN jsonb_build_object('id_activite', v_activite, 'creee', v_creee,
                              'id_occurrence', v_occurrence);
END $$;

COMMENT ON FUNCTION recevoir_activite IS
    'SAN-2, SAN-3 : insère ou met à jour une séance de la montre par sa clé,
     puis la rattache à la séance prévue (SAN-4).';

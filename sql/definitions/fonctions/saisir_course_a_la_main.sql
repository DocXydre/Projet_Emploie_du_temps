-- -----------------------------------------------------------------------------
-- Une course faite sans rien qui l'enregistre                  (MON-12, MON-13)
--
-- Elle entre comme une séance reçue de Santé, sous la clé de l'appareil, et se
-- rattache comme elle : à la course prévue ce jour-là, sinon en séance libre
-- (SAN-4, LIB-5). La note d'effort devient son bilan (SAI-4) et reste dans son
-- détail, pour HAL. La renvoyer ne crée rien de plus (SAI-9). Une séance venue
-- ensuite de la montre ou de Strava prend sa place (SAN-15) ; le bilan reste.
-- Le tout dans une transaction : refusée, elle ne laisse rien.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION saisir_course_a_la_main(
    p_utilisateur   INTEGER,
    p_cle           UUID,
    p_discipline    VARCHAR,
    p_debut         TIMESTAMPTZ,
    p_duree_minutes INTEGER,
    p_effort        INTEGER,
    p_distance_m    INTEGER DEFAULT NULL,
    p_terrain       VARCHAR DEFAULT NULL,
    p_commentaire   TEXT DEFAULT NULL
) RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE
    v_fin        TIMESTAMPTZ;
    v_recue      JSONB;
    v_garde      BIGINT;
    v_occurrence INTEGER;
    v_bilan      JSONB;
BEGIN
    IF p_discipline NOT IN ('course', 'cardio') THEN
        PERFORM refus_coach('requete_invalide', 'Seules une course ou une séance de cardio se déclarent ainsi');
    END IF;
    IF p_effort IS NULL OR p_effort NOT BETWEEN 1 AND 10 THEN
        PERFORM refus_coach('requete_invalide', 'La note d''effort va de 1 à 10');
    END IF;
    IF p_duree_minutes IS NULL OR p_duree_minutes NOT BETWEEN 1 AND 600 THEN
        PERFORM refus_coach('requete_invalide', 'La durée va de 1 minute à 10 heures');
    END IF;
    IF p_distance_m IS NOT NULL AND p_distance_m NOT BETWEEN 1 AND 300000 THEN
        PERFORM refus_coach('requete_invalide', 'La distance va de 1 m à 300 km');
    END IF;
    IF p_terrain IS NOT NULL AND p_terrain NOT IN ('route', 'ville', 'foret', 'trail', 'piste', 'tapis') THEN
        PERFORM refus_coach('requete_invalide', 'Terrain inconnu : route, ville, forêt, trail, piste ou tapis');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM utilisateur u
                    WHERE u.id_utilisateur = p_utilisateur AND u.coach_actif) THEN
        PERFORM refus_coach('coach_inactif',
            'HAL n''est pas actif pour ce compte : une course déclarée à la main se range dans ses séances');
    END IF;
    v_fin := p_debut + make_interval(mins => p_duree_minutes);
    IF v_fin > now() + INTERVAL '5 minutes' THEN
        PERFORM refus_coach('requete_invalide', 'Une course se déclare une fois finie');
    END IF;
    -- SAN-8 : au-delà de 28 jours, elle ne se rattacherait à rien.
    IF jour_de(p_debut) < jour_de(now()) - 28 THEN
        PERFORM refus_coach('requete_invalide', 'Une course de plus de 28 jours ne se déclare plus');
    END IF;

    v_recue := recevoir_activite(
        p_utilisateur, 'main-' || p_cle::TEXT,
        CASE WHEN p_discipline = 'course' THEN 'running' ELSE 'mixedCardio' END,
        p_discipline, p_debut, v_fin,
        jsonb_strip_nulls(jsonb_build_object(
            'duree_secondes', p_duree_minutes * 60,
            'distance_m', p_distance_m,
            'allure_s_km', CASE WHEN p_discipline = 'course' AND p_distance_m > 0
                                THEN LEAST(round(p_duree_minutes * 60000.0 / p_distance_m), 32767) END,
            'details', jsonb_strip_nulls(jsonb_build_object(
                'source', 'Saisie à la main',
                'saisie_manuelle', TRUE,
                'effort', p_effort,
                'terrain', p_terrain,
                'interieur', p_terrain = 'tapis')))));

    -- Déjà reçue d'une appli : c'est sa séance qui porte le bilan.
    v_garde := COALESCE((v_recue ->> 'doublon_de')::BIGINT, (v_recue ->> 'id_activite')::BIGINT);
    SELECT a.id_occurrence INTO v_occurrence FROM activite_sante a WHERE a.id_activite = v_garde;
    IF v_occurrence IS NULL THEN
        PERFORM refus_coach('introuvable', 'Aucune séance où ranger cette course');
    END IF;

    -- Une séance posée à la main n'a pas de contenu (SPT-17) : l'effort reste
    -- alors dans le détail de la séance reçue, sans bilan.
    IF EXISTS (SELECT 1 FROM seance se WHERE se.id_occurrence = v_occurrence) THEN
        v_bilan := enregistrer_bilan(p_utilisateur, v_occurrence, p_effort, p_duree_minutes,
                                     p_commentaire, p_cle);
    END IF;

    RETURN COALESCE(v_bilan, jsonb_build_object('etat', 'sans_bilan', 'id_occurrence', v_occurrence))
        || jsonb_build_object('id_activite', (v_recue ->> 'id_activite')::BIGINT,
                              'doublon_de', (v_recue ->> 'doublon_de')::BIGINT);
END $$;

COMMENT ON FUNCTION saisir_course_a_la_main IS
    'MON-12 : déclare une course ou du cardio faits sans rien qui les enregistre :
     une séance reçue, marquée à la main, rattachée comme les autres, et son
     bilan. Rejouable par la clé de l''appareil.';

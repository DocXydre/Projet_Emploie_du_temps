-- -----------------------------------------------------------------------------
-- Ce qui ne va pas dans une brique                              (CND-3 à CND-6)
--
-- Rend le motif d'un refus, ou rien si la brique est bonne. Le déclencheur de
-- `brique_regle` s'en sert, et `motif_regle` avant même d'écrire : le modèle
-- comme l'appli reçoivent la phrase, pas une erreur de contrainte.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION motif_brique(p_nature         TEXT,
                                        p_pour_qui       TEXT,
                                        p_id_utilisateur INTEGER,
                                        p_parametres     JSONB)
RETURNS TEXT LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_p      JSONB := COALESCE(p_parametres, '{}'::JSONB);
    v_agenda BOOLEAN := p_nature IN ('journee_vide', 'sans_cours_ni_travail', 'demi_journee',
                                     'heures_max', 'veille_sans_cours', 'lendemain_sans_cours',
                                     'temps_libre_min', 'autre_absent', 'tous_presents',
                                     'au_retour', 'avant_depart');
    v_rang   INTEGER;
    v_n      NUMERIC;
BEGIN
    IF p_nature IS NULL OR p_nature NOT IN (
           'jours_semaine', 'dates', 'jour_du_mois', 'jours_interdits',
           'journee_vide', 'sans_cours_ni_travail', 'demi_journee', 'heures_max',
           'veille_sans_cours', 'lendemain_sans_cours', 'temps_libre_min',
           'autre_absent', 'tous_presents', 'au_retour', 'avant_depart') THEN
        RETURN format('Brique inconnue : %s', COALESCE(p_nature, 'sans nom'));
    END IF;
    IF jsonb_typeof(v_p) <> 'object' THEN
        RETURN 'Les paramètres d''une brique sont un objet';
    END IF;

    -- Pour qui : l'agenda et la présence le disent, les jours et les dates non.
    IF v_agenda THEN
        IF p_pour_qui IS NULL OR p_pour_qui NOT IN ('assigne', 'nomme', 'les_deux') THEN
            RETURN 'Cette brique dit pour qui elle vaut : celui qui fait la tâche, un membre, ou les deux';
        END IF;
    ELSIF p_pour_qui IS NOT NULL THEN
        RETURN 'Un jour ou une date vaut pour tout le monde : pas de « pour qui »';
    END IF;
    IF (p_pour_qui = 'nomme') <> (p_id_utilisateur IS NOT NULL) THEN
        RETURN 'Un membre nommé, et seulement avec « pour un membre »';
    END IF;
    IF p_id_utilisateur IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM utilisateur
                        WHERE id_utilisateur = p_id_utilisateur AND actif) THEN
        RETURN 'Ce membre n''existe pas';
    END IF;
    -- Être seul à deux n'a pas de sens.
    IF p_nature = 'autre_absent' AND p_pour_qui = 'les_deux' THEN
        RETURN '« Quand l''autre est absent » vaut pour une seule personne';
    END IF;

    BEGIN
        CASE p_nature
        WHEN 'jours_semaine' THEN
            IF COALESCE(jsonb_typeof(v_p -> 'jours'), '') <> 'array' OR jsonb_array_length(v_p -> 'jours') = 0
               OR EXISTS (SELECT 1 FROM jsonb_array_elements(v_p -> 'jours') j
                           WHERE jsonb_typeof(j) <> 'number' OR j::TEXT::INTEGER NOT BETWEEN 1 AND 7) THEN
                RETURN 'Des jours de la semaine, de 1 (lundi) à 7 (dimanche)';
            END IF;
        WHEN 'dates' THEN
            IF COALESCE(jsonb_typeof(v_p -> 'dates'), '') <> 'array' OR jsonb_array_length(v_p -> 'dates') = 0 THEN
                RETURN 'Au moins une date';
            END IF;
            PERFORM (d #>> '{}')::DATE FROM jsonb_array_elements(v_p -> 'dates') d;
        WHEN 'jour_du_mois' THEN
            IF COALESCE(jsonb_typeof(v_p -> 'rang'), '') <> 'number' THEN
                RETURN 'Un jour du mois : son rang, 1 pour le premier, -1 pour le dernier';
            END IF;
            v_rang := (v_p ->> 'rang')::INTEGER;
            IF v_p ? 'jour_semaine' THEN
                IF COALESCE(jsonb_typeof(v_p -> 'jour_semaine'), '') <> 'number'
                   OR (v_p ->> 'jour_semaine')::INTEGER NOT BETWEEN 1 AND 7 THEN
                    RETURN 'Le jour de la semaine va de 1 (lundi) à 7 (dimanche)';
                END IF;
                IF v_rang = 0 OR v_rang NOT BETWEEN -5 AND 5 THEN
                    RETURN 'Le rang d''un jour de la semaine dans le mois va de 1 à 5, ou de -1 à -5 depuis la fin';
                END IF;
            ELSIF v_rang = 0 OR v_rang NOT BETWEEN -31 AND 31 THEN
                RETURN 'Le jour du mois va de 1 à 31, ou de -1 à -31 depuis la fin';
            END IF;
        WHEN 'jours_interdits' THEN
            IF COALESCE(jsonb_array_length(CASE WHEN jsonb_typeof(v_p -> 'jours') = 'array'
                                                THEN v_p -> 'jours' END), 0)
               + COALESCE(jsonb_array_length(CASE WHEN jsonb_typeof(v_p -> 'dates') = 'array'
                                                  THEN v_p -> 'dates' END), 0) = 0 THEN
                RETURN 'Au moins un jour ou une date interdits';
            END IF;
            IF EXISTS (SELECT 1 FROM jsonb_array_elements(COALESCE(v_p -> 'jours', '[]')) j
                        WHERE jsonb_typeof(j) <> 'number' OR j::TEXT::INTEGER NOT BETWEEN 1 AND 7) THEN
                RETURN 'Des jours de la semaine, de 1 (lundi) à 7 (dimanche)';
            END IF;
            PERFORM (d #>> '{}')::DATE FROM jsonb_array_elements(COALESCE(v_p -> 'dates', '[]')) d;
        WHEN 'demi_journee' THEN
            IF COALESCE(v_p ->> 'partie', '') NOT IN ('matin', 'apres_midi') THEN
                RETURN 'Une demi-journée : le matin ou l''après-midi';
            END IF;
        WHEN 'heures_max' THEN
            v_n := (v_p ->> 'heures')::NUMERIC;
            IF v_n IS NULL OR v_n < 0 OR v_n > 24 THEN
                RETURN 'Un nombre d''heures de cours ou de travail, de 0 à 24';
            END IF;
        WHEN 'temps_libre_min' THEN
            v_n := (v_p ->> 'minutes')::NUMERIC;
            IF v_n IS NULL OR v_n < 1 OR v_n > 1440 OR v_n <> trunc(v_n) THEN
                RETURN 'Un temps libre en minutes, de 1 à 1 440';
            END IF;
        WHEN 'avant_depart' THEN
            v_n := (v_p ->> 'jours_avant')::NUMERIC;
            IF v_n IS NULL OR v_n < 0 OR v_n > 14 OR v_n <> trunc(v_n) THEN
                RETURN 'Un nombre de jours avant le départ, de 0 à 14';
            END IF;
        ELSE
            NULL;
        END CASE;
    EXCEPTION WHEN invalid_datetime_format OR datetime_field_overflow
                   OR invalid_text_representation OR numeric_value_out_of_range THEN
        RETURN 'Une date ou un nombre illisible dans la brique';
    END;

    RETURN NULL;
END $$;

COMMENT ON FUNCTION motif_brique(TEXT, TEXT, INTEGER, JSONB) IS
    'CND-3 à CND-6 : le motif du refus d''une brique, ou rien si elle est bonne.';

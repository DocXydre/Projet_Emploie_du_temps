-- -----------------------------------------------------------------------------
-- Le début d'une séance dans la plage donnée par le coach              (PLN-5)
--
-- Le coach donne une plage d'heures, pas une heure seule : la base y choisit
-- le début qui tient, selon la préférence du lieu (SPT-8, SPT-12). Elle
-- vérifie le placement en mode strict, puis la règle des séances dures.
-- Quand rien ne tient, elle refuse avec le motif du premier essai.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION chercher_debut_seance(
    p_utilisateur INTEGER,
    p_lieu        INTEGER,
    p_jour        DATE,
    p_heure_min   TIME,
    p_heure_max   TIME,
    p_duree       INTEGER,
    p_discipline  VARCHAR,
    p_intensite   VARCHAR,
    p_groupes     TEXT[],
    p_ignorer     INTEGER DEFAULT NULL
) RETURNS TIMESTAMPTZ LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_premier  TIMESTAMPTZ := (p_jour + p_heure_min) AT TIME ZONE 'Europe/Paris';
    v_dernier  TIMESTAMPTZ := (p_jour + p_heure_max) AT TIME ZONE 'Europe/Paris'
                              - make_interval(mins => p_duree);
    v_tard     BOOLEAN;
    v_heure    TIMESTAMPTZ;
    v_obstacle TEXT;
    v_code     TEXT;
    v_motif    TEXT;
    s          RECORD;
    v_jours    TEXT[] := ARRAY['lundi', 'mardi', 'mercredi', 'jeudi', 'vendredi',
                               'samedi', 'dimanche'];
BEGIN
    IF v_dernier < v_premier THEN
        PERFORM refus_coach('creneau_pris',
            format('La plage %s–%s est plus courte que la séance (%s min)',
                   to_char(p_heure_min, 'HH24hMI'), to_char(p_heure_max, 'HH24hMI'), p_duree));
    END IF;

    SELECT l.preference = 'tard' INTO v_tard FROM lieu_sport l WHERE l.id_lieu = p_lieu;

    FOR v_heure IN
        SELECT h FROM generate_series(v_premier, v_dernier, INTERVAL '15 minutes') h
         ORDER BY CASE WHEN COALESCE(v_tard, FALSE) THEN -EXTRACT(EPOCH FROM h)
                       ELSE EXTRACT(EPOCH FROM h) END
    LOOP
        v_obstacle := obstacle_seance_coach(p_utilisateur, p_lieu, v_heure, p_duree,
                                            p_discipline, p_ignorer, TRUE);
        IF v_obstacle IS NOT NULL THEN
            IF v_code IS NULL THEN
                v_code := 'creneau_pris';
                v_motif := format('%s %s : %s', v_jours[EXTRACT(ISODOW FROM p_jour)::INTEGER],
                                  to_char(v_heure AT TIME ZONE 'Europe/Paris', 'HH24hMI'),
                                  v_obstacle);
            END IF;
            CONTINUE;
        END IF;

        SELECT os.code, os.motif INTO s
          FROM obstacle_sportif(p_utilisateur, v_heure, p_intensite, p_groupes,
                                NULL, p_ignorer, TRUE) os
         WHERE os.bloquant
         LIMIT 1;
        IF NOT FOUND THEN
            RETURN v_heure;
        END IF;
        IF v_code IS NULL OR v_code = 'creneau_pris' THEN
            v_code := s.code;
            v_motif := format('%s %s : %s', v_jours[EXTRACT(ISODOW FROM p_jour)::INTEGER],
                              to_char(v_heure AT TIME ZONE 'Europe/Paris', 'HH24hMI'),
                              s.motif);
        END IF;
    END LOOP;

    PERFORM refus_coach(COALESCE(v_code, 'creneau_pris'),
                        COALESCE(v_motif, 'Aucun début ne tient dans cette plage'));
    RETURN NULL;
END $$;

COMMENT ON FUNCTION chercher_debut_seance IS
    'PLN-5 : choisit dans la plage du coach le début qui tient, placement
     strict puis séances dures. Refuse avec le motif quand rien ne tient.';

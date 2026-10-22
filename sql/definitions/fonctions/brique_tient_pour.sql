-- -----------------------------------------------------------------------------
-- Une brique d'agenda ou de présence tient-elle, pour une personne, ce jour-là
--                                                                (CND-5, CND-6)
--
-- Une absence n'est jamais un jour libre : on ne garde pas pour un jour où l'on
-- n'est pas là la tâche qu'on voulait faire chez soi. Le sommeil n'occupe pas
-- la journée ; le sport non plus, qui n'est pas une occupation (TAC-17).
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION brique_tient_pour(p_nature      TEXT,
                                             p_parametres  JSONB,
                                             p_utilisateur INTEGER,
                                             p_jour        DATE)
RETURNS BOOLEAN LANGUAGE plpgsql STABLE AS $$
DECLARE
    -- Annexe 3 : les bornes d'une demi-journée.
    MATIN      CONSTANT TIME := '08:00';
    MIDI       CONSTANT TIME := '13:00';
    SOIR       CONSTANT TIME := '19:00';

    v_jour     TSTZRANGE := tstzrange(debut_jour(p_jour), debut_jour(p_jour + 1), '[)');
    v_plage    TSTZRANGE;
    v_heures   INTERVAL;
BEGIN
    CASE p_nature
    WHEN 'journee_vide' THEN
        RETURN NOT est_absent(p_utilisateur, p_jour)
           AND NOT EXISTS (SELECT 1 FROM occupation
                            WHERE id_utilisateur = p_utilisateur
                              AND type <> 'sommeil'
                              AND periode && v_jour);
    WHEN 'sans_cours_ni_travail' THEN
        RETURN NOT est_absent(p_utilisateur, p_jour) AND journee_libre(p_utilisateur, p_jour);
    WHEN 'demi_journee' THEN
        v_plage := CASE p_parametres ->> 'partie'
                       WHEN 'matin' THEN tstzrange((p_jour + MATIN) AT TIME ZONE 'Europe/Paris',
                                                   (p_jour + MIDI) AT TIME ZONE 'Europe/Paris', '[)')
                       ELSE tstzrange((p_jour + MIDI) AT TIME ZONE 'Europe/Paris',
                                      (p_jour + SOIR) AT TIME ZONE 'Europe/Paris', '[)')
                   END;
        RETURN NOT est_absent(p_utilisateur, p_jour)
           AND NOT EXISTS (SELECT 1 FROM occupation
                            WHERE id_utilisateur = p_utilisateur
                              AND type <> 'sommeil'
                              AND periode && v_plage);
    WHEN 'heures_max' THEN
        SELECT COALESCE(sum(upper(periode * v_jour) - lower(periode * v_jour)), INTERVAL '0')
          INTO v_heures
          FROM occupation
         WHERE id_utilisateur = p_utilisateur
           AND type IN ('cours', 'travail')
           AND periode && v_jour;
        RETURN NOT est_absent(p_utilisateur, p_jour)
           AND v_heures <= make_interval(secs => (p_parametres ->> 'heures')::NUMERIC * 3600);
    WHEN 'veille_sans_cours' THEN
        RETURN NOT est_absent(p_utilisateur, p_jour) AND journee_libre(p_utilisateur, p_jour + 1);
    WHEN 'lendemain_sans_cours' THEN
        RETURN NOT est_absent(p_utilisateur, p_jour) AND journee_libre(p_utilisateur, p_jour - 1);
    WHEN 'temps_libre_min' THEN
        RETURN NOT est_absent(p_utilisateur, p_jour)
           AND temps_libre_jour(p_utilisateur, p_jour)
               >= make_interval(mins => (p_parametres ->> 'minutes')::INTEGER);
    WHEN 'autre_absent' THEN
        RETURN NOT est_absent(p_utilisateur, p_jour) AND seul_ce_jour(p_utilisateur, p_jour);
    WHEN 'tous_presents' THEN
        RETURN NOT EXISTS (SELECT 1 FROM utilisateur
                            WHERE actif AND est_absent(id_utilisateur, p_jour));
    WHEN 'au_retour' THEN
        -- ABS-8 : le jour du retour, ou le lendemain si l'on rentre après 21 h.
        RETURN EXISTS (
            SELECT 1 FROM absence
             WHERE id_utilisateur = p_utilisateur
               AND NOT upper_inf(periode)
               AND ((jour_de(upper(periode)) = p_jour
                     AND (upper(periode) AT TIME ZONE 'Europe/Paris')::TIME < '21:00')
                    OR (jour_de(upper(periode)) = p_jour - 1
                        AND (upper(periode) AT TIME ZONE 'Europe/Paris')::TIME >= '21:00')));
    WHEN 'avant_depart' THEN
        -- TAC-12 : dans les N jours qui précèdent un départ, le jour même compris.
        RETURN NOT est_absent(p_utilisateur, p_jour)
           AND EXISTS (
               SELECT 1 FROM absence
                WHERE id_utilisateur = p_utilisateur
                  AND jour_de(lower(periode)) - p_jour
                      BETWEEN 0 AND (p_parametres ->> 'jours_avant')::INTEGER);
    ELSE
        RETURN TRUE;
    END CASE;
END $$;

COMMENT ON FUNCTION brique_tient_pour(TEXT, JSONB, INTEGER, DATE) IS
    'CND-5, CND-6 : vrai si la brique d''agenda ou de présence tient pour cette personne ce jour-là.';

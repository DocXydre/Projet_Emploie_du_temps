-- -----------------------------------------------------------------------------
-- La meilleure heure d'un sport un jour donné                   (SPT-8, SPT-12)
--
-- Les préférences des lieux sont reprises telles quelles : la piscine au plus
-- tôt, la salle et la course juste après les cours, ou à l'heure par défaut
-- les jours sans cours.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION meilleure_heure_sport(
    p_utilisateur INTEGER,
    p_lieu        INTEGER,
    p_jour        DATE,
    p_ignorer     INTEGER DEFAULT NULL
) RETURNS TIMESTAMPTZ LANGUAGE plpgsql STABLE AS $$
DECLARE
    l       lieu_sport;
    v_ancre TIMESTAMPTZ;
    v_heure TIMESTAMPTZ;
BEGIN
    SELECT * INTO l FROM lieu_sport WHERE id_lieu = p_lieu;

    IF l.preference = 'apres' THEN
        -- Le bloc commence à la fin des cours : la séance, une fois la marge
        -- et le trajet passés.
        v_ancre := COALESCE(fin_des_cours(p_utilisateur, p_jour),
                            (p_jour + l.heure_defaut) AT TIME ZONE 'Europe/Paris')
                   + make_interval(mins => trajet_minutes(p_utilisateur, p_jour, p_lieu)
                                           + l.marge_minutes);
    END IF;

    FOR v_heure IN
        SELECT h FROM heures_candidates(p_lieu, p_jour) h
         ORDER BY CASE WHEN l.preference = 'tard' THEN h END DESC, h
    LOOP
        CONTINUE WHEN v_ancre IS NOT NULL AND v_heure < v_ancre;
        IF obstacle_seance(p_utilisateur, p_lieu, v_heure, p_ignorer, TRUE) IS NULL THEN
            RETURN v_heure;
        END IF;
    END LOOP;

    RETURN NULL;
END $$;

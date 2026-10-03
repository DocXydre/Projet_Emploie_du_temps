-- -----------------------------------------------------------------------------
-- Repos avant la prochaine obligation                                     (SPT-7)
--
-- Ne mord que sur les séances tardives. Une séance de 14h suivie d'un cours à
-- 18h ne pose aucun problème ; c'est celle de 22h30 avant un cours à 8h qui en
-- pose un.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION repos_suffisant(
    p_utilisateur INTEGER,
    p_lieu        INTEGER,
    p_fin         TIMESTAMPTZ
) RETURNS BOOLEAN LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_lieu      lieu_sport;
    v_prochaine TIMESTAMPTZ;
BEGIN
    SELECT * INTO v_lieu FROM lieu_sport WHERE id_lieu = p_lieu;

    IF v_lieu.heure_tardive IS NULL OR v_lieu.repos_heures = 0 THEN
        RETURN TRUE;
    END IF;

    IF (p_fin AT TIME ZONE 'Europe/Paris')::TIME < v_lieu.heure_tardive THEN
        RETURN TRUE;
    END IF;

    SELECT min(lower(o.periode)) INTO v_prochaine
      FROM occupation o
     WHERE o.id_utilisateur = p_utilisateur
       AND o.type IN ('cours', 'travail')
       AND lower(o.periode) >= p_fin;

    RETURN v_prochaine IS NULL
        OR v_prochaine - p_fin >= make_interval(hours => v_lieu.repos_heures);
END $$;

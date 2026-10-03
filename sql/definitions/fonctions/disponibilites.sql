-- -----------------------------------------------------------------------------
-- Disponibilités : l'horizon moins les occupations, moins les créneaux placés
--                                                                        (PLA-1)
--
-- Les multirange de PostgreSQL font tout le travail : on agrège tout ce qui est
-- occupé en un seul multirange, et on le soustrait de l'horizon. Pas de boucle,
-- pas de découpage manuel.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION disponibilites(
    p_utilisateur INTEGER,
    p_debut       TIMESTAMPTZ,
    p_fin         TIMESTAMPTZ
) RETURNS SETOF TSTZRANGE LANGUAGE sql STABLE AS $$
    WITH occupe AS (
        SELECT o.periode AS plage
          FROM occupation o
         WHERE o.id_utilisateur = p_utilisateur
           AND o.periode && tstzrange(p_debut, p_fin, '[)')

        UNION ALL

        -- Les rappels ne réservent pas d'heure précise : ils ne bloquent pas
        -- le calendrier, seulement le volume horaire de la journée.
        SELECT o.creneau
          FROM occurrence o
         WHERE o.id_utilisateur = p_utilisateur
           AND o.creneau IS NOT NULL
           AND NOT o.rappel_journee
           AND o.statut IN ('planifiee', 'notifiee')
           AND o.creneau && tstzrange(p_debut, p_fin, '[)')
    )
    SELECT unnest(
        tstzmultirange(tstzrange(p_debut, p_fin, '[)'))
        - COALESCE((SELECT range_agg(plage) FROM occupe), '{}'::TSTZMULTIRANGE)
    );
$$;

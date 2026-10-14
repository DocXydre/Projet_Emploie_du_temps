-- -----------------------------------------------------------------------------
-- Les heures possibles un jour donné                                   (SPT-24)
--
-- Au quart d'heure, dans les plages d'ouverture. Sert à proposer des heures
-- quand on modifie une séance, plutôt que de les faire écrire.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION heures_candidates(p_lieu INTEGER, p_jour DATE)
RETURNS SETOF TIMESTAMPTZ LANGUAGE sql STABLE AS $$
    SELECT DISTINCT h
      FROM plages_ouvertes(p_lieu, p_jour) p,
           LATERAL generate_series(
               -- Premier quart d'heure de la plage, arrondi vers le haut.
               date_bin(INTERVAL '15 minutes',
                        lower(p) + INTERVAL '15 minutes' - INTERVAL '1 microsecond',
                        debut_jour(p_jour)),
               upper(p) - duree_seance(p_lieu),
               INTERVAL '15 minutes') AS h
     ORDER BY h;
$$;

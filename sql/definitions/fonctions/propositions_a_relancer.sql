-- -----------------------------------------------------------------------------
-- Relancer, une fois                                                      (WKD-5)
--
-- Une seule relance, et seulement si la première annonce est restée sans
-- réponse. Pas de troisième.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION propositions_a_relancer(
    p_jours INTEGER DEFAULT 3
) RETURNS SETOF proposition LANGUAGE sql STABLE AS $$
    SELECT *
      FROM proposition
     WHERE statut = 'proposee'
       AND annoncee_le IS NOT NULL
       AND relancee_le IS NULL
       -- Jamais le jour de l'annonce : un week-end repéré trois jours avant
       -- serait annoncé et relancé dans la foulée.
       AND jour_de(annoncee_le) < jour_de(now())
       AND lower(periode) <= now() + make_interval(days => p_jours)
       AND lower(periode) > now()
     ORDER BY lower(periode);
$$;

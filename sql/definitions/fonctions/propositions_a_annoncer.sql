-- -----------------------------------------------------------------------------
-- Les propositions qui attendent leur annonce                           (WKD-7)
--
-- Repérées, inscrites au calendrier, mais encore muettes. Elles le restent
-- jusqu'à ce que le départ entre dans le délai d'annonce.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION propositions_a_annoncer(
    p_jours INTEGER DEFAULT 7
) RETURNS SETOF proposition LANGUAGE sql STABLE AS $$
    SELECT *
      FROM proposition
     WHERE statut = 'proposee'
       AND annoncee_le IS NULL
       AND lower(periode) <= now() + make_interval(days => p_jours)
       -- Un week-end commencé n'est plus une proposition.
       AND upper(periode) > now()
     ORDER BY lower(periode);
$$;

COMMENT ON FUNCTION propositions_a_annoncer IS
    'Propositions déjà au calendrier mais jamais annoncées, dont le départ
     entre dans le délai : c''est là qu''on en parle (WKD-7).';

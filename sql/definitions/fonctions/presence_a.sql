-- -----------------------------------------------------------------------------
-- Où était le compte à un instant                                (POS-9, SOI-1)
--
-- La présence qui couvre l'instant. Rien si l'on ne sait pas : avant la
-- première position, ou position pas sue.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION presence_a(p_utilisateur INTEGER,
                                      p_instant TIMESTAMPTZ DEFAULT now())
RETURNS presence LANGUAGE sql STABLE AS $$
    SELECT pr.* FROM presence pr
     WHERE pr.id_utilisateur = p_utilisateur AND pr.periode @> p_instant
       AND position_sue(p_utilisateur, GREATEST(p_instant, now() - INTERVAL '1 day'))
     LIMIT 1;
$$;

COMMENT ON FUNCTION presence_a(INTEGER, TIMESTAMPTZ) IS
    'POS-9, SOI-1 : la présence du compte à cet instant, si la position est sue.';

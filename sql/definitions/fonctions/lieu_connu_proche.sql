-- -----------------------------------------------------------------------------
-- Le lieu connu où se trouve une position                              (POS-3)
--
-- Le plus proche de ceux dont elle est dans le rayon, élargi de la précision
-- du relevé jusqu'à 100 m au plus. Vide : ailleurs.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION lieu_connu_proche(
    p_utilisateur INTEGER,
    p_latitude    NUMERIC,
    p_longitude   NUMERIC,
    p_precision   NUMERIC DEFAULT 0
) RETURNS INTEGER LANGUAGE sql STABLE AS $$
    SELECT l.id_lieu_connu
      FROM lieux_du_compte(p_utilisateur) l,
           LATERAL (SELECT distance_m(l.latitude, l.longitude, p_latitude, p_longitude) AS d) x
     WHERE x.d <= l.rayon_m + LEAST(GREATEST(COALESCE(p_precision, 0), 0), 100)
     ORDER BY x.d
     LIMIT 1;
$$;

COMMENT ON FUNCTION lieu_connu_proche(INTEGER, NUMERIC, NUMERIC, NUMERIC) IS
    'POS-3 : le lieu connu le plus proche dont la position est dans le rayon, élargi de la précision (100 m au plus).';

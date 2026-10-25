-- -----------------------------------------------------------------------------
-- Distance entre deux points, en mètres                          (ADR-7, POS-3)
--
-- La formule de haversine, sur une Terre ronde de 6 371 km. À l'échelle d'une
-- ville, l'erreur est de quelques mètres : bien moins que la précision d'un
-- relevé de l'iPhone.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION distance_m(
    p_lat1 NUMERIC, p_lon1 NUMERIC, p_lat2 NUMERIC, p_lon2 NUMERIC
) RETURNS DOUBLE PRECISION LANGUAGE sql IMMUTABLE AS $$
    SELECT 2 * 6371000 * asin(sqrt(
        power(sin(radians(p_lat2 - p_lat1) / 2), 2)
        + cos(radians(p_lat1)) * cos(radians(p_lat2))
          * power(sin(radians(p_lon2 - p_lon1) / 2), 2)));
$$;

COMMENT ON FUNCTION distance_m(NUMERIC, NUMERIC, NUMERIC, NUMERIC) IS
    'La distance à vol d''oiseau entre deux points, en mètres (haversine).';

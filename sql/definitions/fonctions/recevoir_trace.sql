-- -----------------------------------------------------------------------------
-- Le tracé GPS d'une séance                                             (SAN-14)
--
-- Point par point, tel que l'iPhone ou la montre l'a enregistré. Un point hors
-- des coordonnées possibles est écarté. Renvoyé, un point met à jour celui du
-- même instant.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION recevoir_trace(p_utilisateur INTEGER, p_cle VARCHAR, p_lot JSONB)
RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE
    v_activite BIGINT := activite_par_cle(p_utilisateur, p_cle);
    v_total    INTEGER := verifier_lot_sante(p_lot);
    v_gardes   INTEGER;
BEGIN
    WITH bons AS (
        SELECT DISTINCT ON (l.instant) l.*
          FROM jsonb_to_recordset(p_lot)
               AS l(instant TIMESTAMPTZ, latitude NUMERIC, longitude NUMERIC,
                    altitude_m NUMERIC, precision_m NUMERIC, vitesse_ms NUMERIC)
         WHERE l.instant IS NOT NULL
           AND l.latitude BETWEEN -90 AND 90 AND l.longitude BETWEEN -180 AND 180
           AND (l.altitude_m IS NULL OR l.altitude_m BETWEEN -500 AND 9000)
           AND (l.precision_m IS NULL OR l.precision_m BETWEEN 0 AND 9999)
           AND (l.vitesse_ms IS NULL OR l.vitesse_ms BETWEEN 0 AND 999)
         ORDER BY l.instant
    ), entrees AS (
        INSERT INTO activite_trace AS t (id_activite, instant, latitude, longitude,
                                         altitude_m, precision_m, vitesse_ms)
        SELECT v_activite, b.instant, round(b.latitude, 6), round(b.longitude, 6),
               round(b.altitude_m, 1), round(b.precision_m, 1), round(b.vitesse_ms, 2)
          FROM bons b
        ON CONFLICT (id_activite, instant) DO UPDATE
           SET latitude = EXCLUDED.latitude, longitude = EXCLUDED.longitude,
               altitude_m = EXCLUDED.altitude_m, precision_m = EXCLUDED.precision_m,
               vitesse_ms = EXCLUDED.vitesse_ms
        RETURNING 1
    )
    SELECT count(*) INTO v_gardes FROM entrees;

    UPDATE activite_sante SET recue_le = now() WHERE id_activite = v_activite;
    RETURN jsonb_build_object('gardees', v_gardes, 'ecartees', v_total - v_gardes);
END $$;

COMMENT ON FUNCTION recevoir_trace(INTEGER, VARCHAR, JSONB) IS
    'SAN-14 : garde le tracé GPS d''une séance de la montre, point par point.
     Rend le nombre de points gardés et écartés.';

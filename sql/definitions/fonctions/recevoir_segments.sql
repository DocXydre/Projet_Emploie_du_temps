-- -----------------------------------------------------------------------------
-- Le découpage d'une séance                                             (SAN-13)
--
-- Les kilomètres, les étapes (ce qu'une séance envoyée à la montre prévoyait,
-- MON-1), les tours et les pauses. L'appli envoie un découpage entier : il
-- remplace celui de la même sorte déjà reçu. Un segment sans durée ou sans
-- rang est écarté.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION recevoir_segments(p_utilisateur INTEGER, p_cle VARCHAR, p_lot JSONB)
RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE
    v_activite BIGINT := activite_par_cle(p_utilisateur, p_cle);
    v_total    INTEGER := verifier_lot_sante(p_lot);
    v_gardes   INTEGER;
BEGIN
    CREATE TEMP TABLE lot_segment ON COMMIT DROP AS
    SELECT DISTINCT ON (l.sorte, l.rang) l.*
      FROM jsonb_to_recordset(p_lot)
           AS l(sorte TEXT, rang INTEGER, debut TIMESTAMPTZ, fin TIMESTAMPTZ,
                distance_m NUMERIC, libelle TEXT, prevu JSONB, details JSONB)
     WHERE l.sorte IN ('kilometre', 'etape', 'tour', 'pause')
       AND l.rang BETWEEN 1 AND 32000
       AND l.debut IS NOT NULL AND l.fin > l.debut
       AND (l.distance_m IS NULL OR l.distance_m BETWEEN 0 AND 9999999)
     ORDER BY l.sorte, l.rang;

    DELETE FROM activite_segment
     WHERE id_activite = v_activite AND sorte IN (SELECT sorte FROM lot_segment);
    INSERT INTO activite_segment (id_activite, sorte, rang, periode, distance_m, libelle,
                                  prevu, details)
    SELECT v_activite, s.sorte, s.rang, tstzrange(s.debut, s.fin, '[)'), s.distance_m,
           left(s.libelle, 60), s.prevu, COALESCE(s.details, '{}')
      FROM lot_segment s;
    GET DIAGNOSTICS v_gardes = ROW_COUNT;
    DROP TABLE lot_segment;

    UPDATE activite_sante SET recue_le = now() WHERE id_activite = v_activite;
    RETURN jsonb_build_object('gardees', v_gardes, 'ecartees', v_total - v_gardes);
END $$;

COMMENT ON FUNCTION recevoir_segments(INTEGER, VARCHAR, JSONB) IS
    'SAN-13 : remplace le découpage d''une séance de la montre, sorte par
     sorte (kilomètres, étapes, tours, pauses). Rend le nombre de segments
     gardés et écartés.';

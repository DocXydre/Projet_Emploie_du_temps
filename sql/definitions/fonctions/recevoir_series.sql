-- -----------------------------------------------------------------------------
-- Les mesures prises pendant une séance                         (SAN-11, SAN-12)
--
-- Chaque mesure telle que la montre l'a prise : FC, vitesse, cadence,
-- puissance, foulée, contact au sol, oscillation, distance. Une mesure hors
-- des bornes de sa grandeur, ou trop loin de la séance (plus de 10 minutes
-- avant ou après), est écartée ; le reste du lot entre. Renvoyée, une mesure
-- met à jour la précédente au même instant, sans doublon.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION recevoir_series(p_utilisateur INTEGER, p_cle VARCHAR, p_lot JSONB)
RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE
    v_activite BIGINT := activite_par_cle(p_utilisateur, p_cle);
    v_total    INTEGER := verifier_lot_sante(p_lot);
    v_periode  TSTZRANGE;
    v_gardees  INTEGER;
BEGIN
    SELECT periode INTO v_periode FROM activite_sante WHERE id_activite = v_activite;

    WITH bons AS (
        SELECT DISTINCT ON (l.grandeur, l.debut) l.*
          FROM jsonb_to_recordset(p_lot)
               AS l(grandeur TEXT, debut TIMESTAMPTZ, fin TIMESTAMPTZ, valeur DOUBLE PRECISION)
          JOIN grandeur_sante g ON g.code = l.grandeur AND g.portee IN ('seance', 'les_deux')
         WHERE l.debut IS NOT NULL AND l.valeur BETWEEN g.minimum AND g.maximum
           AND (l.fin IS NULL OR l.fin >= l.debut)
           AND l.debut BETWEEN lower(v_periode) - INTERVAL '10 minutes'
                           AND upper(v_periode) + INTERVAL '10 minutes'
         ORDER BY l.grandeur, l.debut
    ), entrees AS (
        INSERT INTO activite_serie AS s (id_activite, grandeur, debut, fin, valeur)
        SELECT v_activite, b.grandeur, b.debut, b.fin, b.valeur FROM bons b
        ON CONFLICT (id_activite, grandeur, debut) DO UPDATE
           SET fin = EXCLUDED.fin, valeur = EXCLUDED.valeur
        RETURNING 1
    )
    SELECT count(*) INTO v_gardees FROM entrees;

    UPDATE activite_sante SET recue_le = now() WHERE id_activite = v_activite;
    RETURN jsonb_build_object('gardees', v_gardees, 'ecartees', v_total - v_gardees);
END $$;

COMMENT ON FUNCTION recevoir_series(INTEGER, VARCHAR, JSONB) IS
    'SAN-11, SAN-12 : garde les mesures brutes d''une séance de la montre.
     Écarte ce qui sort des bornes de sa grandeur ou de la séance. Rend le
     nombre de mesures gardées et écartées.';

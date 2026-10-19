-- -----------------------------------------------------------------------------
-- Le quotidien, mesure par mesure                               (SAN-12, SAN-15)
--
-- La FC de toute la journée, la VFC, la VO2max, la FC de récupération, le
-- poids, la SpO2, la respiration, la température du poignet, l'énergie
-- active. Chaque mesure garde sa clé de Santé, sa source et son appareil.
-- Renvoyée, elle met à jour sans doublon. Une mesure hors bornes, ou venue
-- du futur, est écartée.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION recevoir_echantillons(p_utilisateur INTEGER, p_lot JSONB)
RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE
    v_total  INTEGER := verifier_lot_sante(p_lot);
    v_gardes INTEGER;
BEGIN
    WITH bons AS (
        SELECT DISTINCT ON (l.cle) l.*
          FROM jsonb_to_recordset(p_lot)
               AS l(cle TEXT, grandeur TEXT, debut TIMESTAMPTZ, fin TIMESTAMPTZ,
                    valeur DOUBLE PRECISION, source TEXT, appareil TEXT)
          JOIN grandeur_sante g ON g.code = l.grandeur AND g.portee IN ('quotidien', 'les_deux')
         WHERE l.cle IS NOT NULL AND length(l.cle) <= 64
           AND l.debut IS NOT NULL AND l.debut <= now() + INTERVAL '5 minutes'
           AND (l.fin IS NULL OR l.fin >= l.debut)
           AND l.valeur BETWEEN g.minimum AND g.maximum
         ORDER BY l.cle
    ), entrees AS (
        INSERT INTO echantillon_sante AS e (id_utilisateur, cle_externe, grandeur, periode,
                                            valeur, source, appareil)
        SELECT p_utilisateur, b.cle, b.grandeur,
               tstzrange(b.debut, COALESCE(b.fin, b.debut), '[]'), b.valeur,
               left(b.source, 80), left(b.appareil, 40)
          FROM bons b
        ON CONFLICT (id_utilisateur, cle_externe) DO UPDATE
           SET grandeur = EXCLUDED.grandeur, periode = EXCLUDED.periode,
               valeur = EXCLUDED.valeur, source = EXCLUDED.source,
               appareil = EXCLUDED.appareil, recue_le = now()
        RETURNING 1
    )
    SELECT count(*) INTO v_gardes FROM entrees;
    RETURN jsonb_build_object('gardees', v_gardes, 'ecartees', v_total - v_gardes);
END $$;

COMMENT ON FUNCTION recevoir_echantillons(INTEGER, JSONB) IS
    'SAN-12, SAN-15 : garde les mesures du quotidien venues de Santé, avec leur
     source. Écarte ce qui sort des bornes ou vient du futur. Rend le nombre de
     mesures gardées et écartées.';

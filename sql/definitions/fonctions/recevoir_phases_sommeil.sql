-- -----------------------------------------------------------------------------
-- Le sommeil phase par phase                                            (SAN-16)
--
-- Au lit, endormi, éveillé, léger, profond, paradoxal : chaque phase telle que
-- Santé la donne, avec sa source. La montre donne les phases ; l'iPhone seul
-- ne donne que « au lit » ou « endormi ». Renvoyée, une phase met à jour sans
-- doublon. Une phase sans durée, ou venue du futur, est écartée.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION recevoir_phases_sommeil(p_utilisateur INTEGER, p_lot JSONB)
RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE
    v_total  INTEGER := verifier_lot_sante(p_lot);
    v_gardes INTEGER;
BEGIN
    WITH bons AS (
        SELECT DISTINCT ON (l.cle) l.*
          FROM jsonb_to_recordset(p_lot)
               AS l(cle TEXT, phase TEXT, debut TIMESTAMPTZ, fin TIMESTAMPTZ,
                    source TEXT, appareil TEXT)
         WHERE l.cle IS NOT NULL AND length(l.cle) <= 64
           AND l.phase IN ('au_lit', 'endormi', 'eveille', 'leger', 'profond', 'paradoxal')
           AND l.debut IS NOT NULL AND l.fin > l.debut
           AND l.fin <= now() + INTERVAL '5 minutes'
           AND l.fin - l.debut <= INTERVAL '24 hours'
         ORDER BY l.cle
    ), entrees AS (
        INSERT INTO sommeil_phase AS s (id_utilisateur, cle_externe, phase, periode, source,
                                        appareil)
        SELECT p_utilisateur, b.cle, b.phase, tstzrange(b.debut, b.fin, '[)'),
               left(b.source, 80), left(b.appareil, 40)
          FROM bons b
        ON CONFLICT (id_utilisateur, cle_externe) DO UPDATE
           SET phase = EXCLUDED.phase, periode = EXCLUDED.periode,
               source = EXCLUDED.source, appareil = EXCLUDED.appareil, recue_le = now()
        RETURNING 1
    )
    SELECT count(*) INTO v_gardes FROM entrees;
    RETURN jsonb_build_object('gardees', v_gardes, 'ecartees', v_total - v_gardes);
END $$;

COMMENT ON FUNCTION recevoir_phases_sommeil(INTEGER, JSONB) IS
    'SAN-16 : garde les phases du sommeil venues de Santé, avec leur source.
     Rend le nombre de phases gardées et écartées.';

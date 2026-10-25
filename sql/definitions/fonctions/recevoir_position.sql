-- -----------------------------------------------------------------------------
-- Une position envoyée par l'iPhone                     (opération H2 : POS-2 à POS-4)
--
-- La dernière position est écrasée ; l'état de l'autorisation est noté même
-- sans coordonnées. Un relevé moins précis que 200 m ne change pas le lieu. Si
-- le lieu change, la présence en cours se ferme à l'instant du relevé et une
-- autre s'ouvre. Un relevé plus ancien que la présence en cours (arrivé en
-- retard, l'iPhone était hors réseau) ne la défait pas.
--
-- Sans coordonnées, l'iPhone peut dire seulement qu'il est sorti d'un lieu :
-- réveillé par la sortie d'un cercle, il n'a pas toujours le temps d'un relevé.
-- Si l'on était dans ce lieu, on passe ailleurs.
--
-- Rend le lieu trouvé, et s'il a changé, ce qu'était le précédent : c'est ce
-- qui fait poser une question au HAL du foyer (POS-7, POS-8).
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION recevoir_position(
    p_utilisateur  INTEGER,
    p_latitude     NUMERIC,
    p_longitude    NUMERIC,
    p_precision    NUMERIC,
    p_instant      TIMESTAMPTZ,
    p_autorisation VARCHAR,
    p_precise      BOOLEAN,
    p_sortie_de    INTEGER DEFAULT NULL
) RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE
    v_instant   TIMESTAMPTZ := LEAST(COALESCE(p_instant, now()), now());
    v_lieu      INTEGER;
    v_en_cours  presence;
    v_change    BOOLEAN := FALSE;
    v_id        BIGINT;
BEGIN
    INSERT INTO position_actuelle AS p (id_utilisateur, latitude, longitude, precision_m,
                                        releve_le, autorisation, precise, ecrit_le)
    VALUES (p_utilisateur, p_latitude, p_longitude, p_precision,
            CASE WHEN p_latitude IS NOT NULL THEN v_instant END,
            COALESCE(p_autorisation, 'inconnue'), COALESCE(p_precise, FALSE), now())
    ON CONFLICT (id_utilisateur) DO UPDATE
       SET latitude     = COALESCE(EXCLUDED.latitude, p.latitude),
           longitude    = COALESCE(EXCLUDED.longitude, p.longitude),
           precision_m  = COALESCE(EXCLUDED.precision_m, p.precision_m),
           releve_le    = COALESCE(EXCLUDED.releve_le, p.releve_le),
           autorisation = EXCLUDED.autorisation,
           precise      = EXCLUDED.precise,
           ecrit_le     = now();

    SELECT * INTO v_en_cours FROM presence
     WHERE id_utilisateur = p_utilisateur AND upper_inf(periode);

    IF p_latitude IS NULL AND p_sortie_de IS NOT NULL
       AND v_en_cours.id_lieu_connu = p_sortie_de
       AND lower(v_en_cours.periode) < v_instant THEN
        UPDATE presence SET periode = tstzrange(lower(periode), v_instant, '[)')
         WHERE id_presence = v_en_cours.id_presence;
        INSERT INTO presence (id_utilisateur, id_lieu_connu, periode)
        VALUES (p_utilisateur, NULL, tstzrange(v_instant, NULL, '[)'))
        RETURNING id_presence INTO v_id;
        RETURN jsonb_build_object('id_lieu_connu', NULL, 'change', TRUE, 'id_presence', v_id,
                                  'pris_en_compte', TRUE, 'precedent', p_sortie_de);
    END IF;

    IF p_latitude IS NULL OR p_longitude IS NULL OR COALESCE(p_precision, 0) > 200
       OR lower(v_en_cours.periode) >= v_instant THEN
        RETURN jsonb_build_object(
            'id_lieu_connu', v_en_cours.id_lieu_connu, 'change', FALSE,
            'id_presence', v_en_cours.id_presence, 'pris_en_compte', FALSE);
    END IF;

    v_lieu := lieu_connu_proche(p_utilisateur, p_latitude, p_longitude, p_precision);

    IF v_en_cours.id_presence IS NULL THEN
        INSERT INTO presence (id_utilisateur, id_lieu_connu, periode)
        VALUES (p_utilisateur, v_lieu, tstzrange(v_instant, NULL, '[)'))
        RETURNING id_presence INTO v_id;
        v_change := TRUE;
    ELSIF v_en_cours.id_lieu_connu IS DISTINCT FROM v_lieu THEN
        UPDATE presence SET periode = tstzrange(lower(periode), v_instant, '[)')
         WHERE id_presence = v_en_cours.id_presence;
        INSERT INTO presence (id_utilisateur, id_lieu_connu, periode)
        VALUES (p_utilisateur, v_lieu, tstzrange(v_instant, NULL, '[)'))
        RETURNING id_presence INTO v_id;
        v_change := TRUE;
    ELSE
        v_id := v_en_cours.id_presence;
    END IF;

    RETURN jsonb_build_object(
        'id_lieu_connu', v_lieu, 'change', v_change, 'id_presence', v_id,
        'pris_en_compte', TRUE,
        'precedent', CASE WHEN v_change THEN v_en_cours.id_lieu_connu END,
        'avait_une_presence', v_en_cours.id_presence IS NOT NULL);
END $$;

COMMENT ON FUNCTION recevoir_position(INTEGER, NUMERIC, NUMERIC, NUMERIC, TIMESTAMPTZ,
                                      VARCHAR, BOOLEAN, INTEGER) IS
    'POS-2 à POS-4 : écrase la dernière position, et ouvre une présence si le lieu change.';

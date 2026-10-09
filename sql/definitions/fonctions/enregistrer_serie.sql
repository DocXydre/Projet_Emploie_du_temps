-- -----------------------------------------------------------------------------
-- Une série saisie pendant la séance                 (SAI-1, SAI-2, SAI-9, SAI-11)
--
-- La clé créée par l'appareil rend l'envoi répétable : la même clé renvoyée ne
-- crée rien de plus et rend la ligne en place. L'heure gardée est celle de la
-- saisie, pas celle de l'arrivée. L'exercice interdit et la forme de la mesure
-- sont contrôlés par le déclencheur de la table (SEC-1).
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION enregistrer_serie(
    p_utilisateur     INTEGER,
    p_occurrence      INTEGER,
    p_exercice        INTEGER,
    p_cle_client      UUID,
    p_numero          INTEGER     DEFAULT NULL,
    p_charge          NUMERIC     DEFAULT NULL,
    p_repetitions     INTEGER     DEFAULT NULL,
    p_duree           INTEGER     DEFAULT NULL,
    p_distance        INTEGER     DEFAULT NULL,
    p_marge           INTEGER     DEFAULT NULL,
    p_saisie_le       TIMESTAMPTZ DEFAULT NULL,
    p_seance_exercice INTEGER     DEFAULT NULL
) RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE
    v_serie  BIGINT;
    v_numero INTEGER;
    v_prevue INTEGER := p_seance_exercice;
BEGIN
    SELECT ss.id_serie INTO v_serie FROM serie_saisie ss WHERE ss.cle_client = p_cle_client;
    IF v_serie IS NOT NULL THEN
        RETURN jsonb_build_object('etat', 'existait', 'id_serie', v_serie);
    END IF;

    IF NOT EXISTS (SELECT 1 FROM seance se JOIN occurrence o
                       ON o.id_occurrence = se.id_occurrence
                    WHERE se.id_occurrence = p_occurrence
                      AND o.id_utilisateur = p_utilisateur) THEN
        PERFORM refus_coach('introuvable', 'Séance introuvable');
    END IF;

    -- SAI-2 : la série se rattache à la ligne prévue quand il y en a une.
    IF v_prevue IS NULL THEN
        SELECT se.id_seance_exercice INTO v_prevue
          FROM seance_exercice se
         WHERE se.id_occurrence = p_occurrence AND se.id_exercice = p_exercice
         ORDER BY se.rang LIMIT 1;
    ELSIF NOT EXISTS (SELECT 1 FROM seance_exercice se
                       WHERE se.id_seance_exercice = v_prevue
                         AND se.id_occurrence = p_occurrence) THEN
        PERFORM refus_coach('introuvable', 'Cette ligne prévue n''est pas dans la séance');
    END IF;

    v_numero := COALESCE(p_numero,
        (SELECT COALESCE(max(ss.numero), 0) + 1 FROM serie_saisie ss
          WHERE ss.id_occurrence = p_occurrence AND ss.id_exercice = p_exercice));

    INSERT INTO serie_saisie (id_occurrence, id_exercice, id_seance_exercice, numero,
                              charge_kg, repetitions, duree_secondes, distance_m,
                              marge_repetitions, saisie_le, cle_client)
    VALUES (p_occurrence, p_exercice, v_prevue, v_numero, p_charge, p_repetitions,
            p_duree, p_distance, p_marge, COALESCE(p_saisie_le, now()), p_cle_client)
    RETURNING id_serie INTO v_serie;

    RETURN jsonb_build_object('etat', 'creee', 'id_serie', v_serie, 'numero', v_numero);
END $$;

COMMENT ON FUNCTION enregistrer_serie IS
    'SAI-1, SAI-2, SAI-9 : enregistre une série. La même clé d''appareil ne
     crée rien de plus et rend la ligne en place.';

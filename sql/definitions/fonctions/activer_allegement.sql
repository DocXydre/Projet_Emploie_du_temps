-- -----------------------------------------------------------------------------
-- Passer en mode allégé                                                (PLA-16)
--
-- Pour un nombre de jours, aujourd'hui compris : « 3 » court jusqu'à
-- après-demain soir. Relancer le mode pendant qu'il tourne en change la durée,
-- il ne s'empile pas.
--
-- La semaine est rouverte à la répartition, comme quand on reprend la tâche de
-- quelqu'un : ce qui n'a pas été annoncé se redistribue au placement suivant.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION activer_allegement(p_utilisateur INTEGER, p_jours INTEGER)
RETURNS TSTZRANGE LANGUAGE plpgsql AS $$
DECLARE
    v_periode TSTZRANGE;
BEGIN
    IF p_jours IS NULL OR p_jours < 1 OR p_jours > 14 THEN
        RAISE EXCEPTION 'Le mode allégé dure de 1 à 14 jours'
              USING ERRCODE = 'check_violation';
    END IF;

    v_periode := tstzrange(now(), debut_jour(jour_de(now()) + p_jours), '[)');

    -- Celui qui tourne déjà, ou ceux qui étaient prévus sur ces jours-là, sont
    -- remplacés.
    DELETE FROM allegement
     WHERE id_utilisateur = p_utilisateur AND periode && v_periode;

    INSERT INTO allegement (id_utilisateur, periode) VALUES (p_utilisateur, v_periode);

    PERFORM reequilibrer(p_jours + 1);
    RETURN v_periode;
END $$;

COMMENT ON FUNCTION activer_allegement(INTEGER, INTEGER) IS
    'PLA-16 : met quelqu''un en mode allégé pour 1 à 14 jours, aujourd''hui
     compris, et rouvre ces jours à la répartition.';

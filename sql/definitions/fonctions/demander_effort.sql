-- -----------------------------------------------------------------------------
-- Une course arrivée sans la montre demande son effort                 (MON-11)
--
-- Appelée à la réception d'une séance. Si elle attend sa note (voir
-- efforts_a_donner) et a moins d'un jour, une notification la demande, une
-- seule fois par séance : l'historique envoyé d'un coup ne réveille personne.
-- Rend vrai si une notification est écrite.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION demander_effort(p_activite BIGINT)
RETURNS BOOLEAN LANGUAGE plpgsql AS $$
DECLARE
    e       RECORD;
    v_quoi  TEXT;
BEGIN
    SELECT f.*, a.id_utilisateur INTO e
      FROM activite_sante a, efforts_a_donner(a.id_utilisateur) f
     WHERE a.id_activite = p_activite AND f.id_occurrence = a.id_occurrence
       AND f.debut > now() - INTERVAL '1 day';
    IF NOT FOUND THEN
        RETURN FALSE;
    END IF;
    IF EXISTS (SELECT 1 FROM notification n
                WHERE n.id_occurrence = e.id_occurrence AND n.type = 'sport'
                  AND n.contenu LIKE '%quel effort%') THEN
        RETURN FALSE;
    END IF;

    v_quoi := CASE WHEN e.discipline = 'course' THEN 'Course' ELSE 'Cardio' END
        || CASE WHEN e.distance_m > 0
                THEN ' de ' || replace(round(e.distance_m / 1000.0, 1)::TEXT, '.', ',') || ' km'
                ELSE ' de ' || CEIL(e.duree_secondes / 60.0)::INTEGER || ' min' END
        || CASE WHEN e.source IS NOT NULL THEN ' reçue de ' || e.source ELSE ' reçue' END;
    INSERT INTO notification (id_utilisateur, id_occurrence, type, contenu)
    VALUES (e.id_utilisateur, e.id_occurrence, 'sport',
            v_quoi || ' : quel effort, de 1 à 10 ? HAL en tire la charge de la séance.');
    RETURN TRUE;
END $$;

COMMENT ON FUNCTION demander_effort(BIGINT) IS
    'MON-11 : notifie une fois la course ou le cardio reçus sans la montre, de
     moins d''un jour, pour demander la note d''effort.';

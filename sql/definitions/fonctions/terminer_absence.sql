-- -----------------------------------------------------------------------------
-- Déclarer son retour                                                     (ABS-6)
--
-- Un trajet prévu n'engage à rien. Fermer l'absence à l'instant présent rend
-- au ménage les jours qui restaient gelés — y compris celui-ci, puisqu'une
-- journée ne compte absente que si elle est entièrement couverte.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION terminer_absence(
    p_utilisateur INTEGER,
    p_instant     TIMESTAMPTZ DEFAULT now()
) RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE
    v_absence absence;
BEGIN
    SELECT * INTO v_absence
      FROM absence
     WHERE id_utilisateur = p_utilisateur
       AND periode @> p_instant
     ORDER BY lower(periode)
     LIMIT 1;

    IF NOT FOUND THEN
        -- Rentrer d'un voyage qu'on n'a pas commencé n'est pas une erreur à
        -- signaler par une exception : l'appelant a besoin de le dire
        -- gentiment, pas d'attraper une panne.
        RETURN NULL;
    END IF;

    IF lower(v_absence.periode) >= p_instant THEN
        DELETE FROM absence WHERE id_absence = v_absence.id_absence;
        RETURN v_absence.id_absence;
    END IF;

    UPDATE absence
       SET periode = tstzrange(lower(periode), p_instant, '[)'),
           commentaire = COALESCE(commentaire || ' — ', '') || 'retour déclaré'
     WHERE id_absence = v_absence.id_absence;

    RETURN v_absence.id_absence;
END $$;

COMMENT ON FUNCTION terminer_absence IS
    'Ferme l''absence en cours à l''instant donné, et rend les jours restants '
    'au ménage (ABS-6).';

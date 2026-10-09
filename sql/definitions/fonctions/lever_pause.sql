CREATE OR REPLACE FUNCTION lever_pause(p_utilisateur INTEGER)
RETURNS BOOLEAN LANGUAGE plpgsql AS $$
DECLARE
    v_jour DATE := jour_de(now());
    p      RECORD;
BEGIN
    SELECT pa.id_pause, lower(pa.periode) AS debut INTO p
      FROM pause pa
     WHERE pa.id_utilisateur = p_utilisateur AND pa.periode @> v_jour;
    IF NOT FOUND THEN
        RETURN FALSE;
    END IF;

    -- Lever une pause ferme sa période au lieu de l'effacer : ce qui s'est
    -- passé pendant qu'elle courait garde son explication. Une pause levée le
    -- jour même n'a rien couvert, et s'efface.
    IF p.debut >= v_jour THEN
        DELETE FROM pause WHERE id_pause = p.id_pause;
    ELSE
        UPDATE pause SET periode = daterange(p.debut, v_jour, '[)')
         WHERE id_pause = p.id_pause;
    END IF;
    RETURN TRUE;
END $$;

COMMENT ON FUNCTION lever_pause(INTEGER) IS
    'PAU-1, PAU-6 : lève la pause en cours en fermant sa période à la date du
     jour. Rend faux s''il n''y avait pas de pause.';

-- -----------------------------------------------------------------------------
-- Sortir du mode allégé avant la fin                                   (PLA-16)
--
-- La période est fermée à l'instant présent plutôt qu'effacée : ce qui a été
-- réparti pendant qu'elle courait garde son explication.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION arreter_allegement(p_utilisateur INTEGER)
RETURNS BOOLEAN LANGUAGE plpgsql AS $$
DECLARE
    v_arretes INTEGER;
BEGIN
    DELETE FROM allegement
     WHERE id_utilisateur = p_utilisateur AND lower(periode) >= now();
    GET DIAGNOSTICS v_arretes = ROW_COUNT;

    UPDATE allegement
       SET periode = tstzrange(lower(periode), now(), '[)')
     WHERE id_utilisateur = p_utilisateur
       AND periode @> now()
       AND lower(periode) < now();
    IF FOUND THEN
        v_arretes := v_arretes + 1;
    END IF;

    IF v_arretes > 0 THEN
        PERFORM reequilibrer(15);
    END IF;
    RETURN v_arretes > 0;
END $$;

COMMENT ON FUNCTION arreter_allegement(INTEGER) IS
    'PLA-16 : met fin au mode allégé de quelqu''un et rouvre les jours à venir
     à la répartition. Rend faux s''il n''était pas actif.';

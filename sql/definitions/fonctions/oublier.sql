CREATE OR REPLACE FUNCTION oublier(p_utilisateur INTEGER, p_note INTEGER)
RETURNS INTEGER LANGUAGE plpgsql AS $$
BEGIN
    DELETE FROM note_coach n
     WHERE n.id_note = p_note AND n.id_utilisateur = p_utilisateur;
    IF NOT FOUND THEN
        PERFORM refus_coach('introuvable', 'Cette note n''est pas dans le carnet');
    END IF;
    RETURN p_note;
END $$;

COMMENT ON FUNCTION oublier(INTEGER, INTEGER) IS
    'CAR-9 : retire une note du carnet. Elle est supprimée, pas masquée.';

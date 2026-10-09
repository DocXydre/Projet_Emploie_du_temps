CREATE OR REPLACE FUNCTION restaurer_memoire(p_utilisateur INTEGER, p_memoire BIGINT)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE
    v memoire_coach%ROWTYPE;
BEGIN
    SELECT * INTO v FROM memoire_coach m
     WHERE m.id_memoire = p_memoire AND m.id_utilisateur = p_utilisateur;
    IF NOT FOUND THEN
        PERFORM refus_coach('introuvable', 'Cette version de la mémoire n''existe pas');
    END IF;
    -- La version restaurée redevient la dernière. Elle passe par les mêmes
    -- contrôles, sauf la longueur : elle a déjà été admise une fois.
    INSERT INTO memoire_coach (id_utilisateur, niveau, periode, texte, auteur,
                               couvre_jusqu_au)
    SELECT v.id_utilisateur, v.niveau, v.periode, v.texte, 'utilisateur',
           (SELECT m.couvre_jusqu_au FROM memoire_coach m
             WHERE m.id_utilisateur = v.id_utilisateur AND m.niveau = v.niveau
               AND m.periode IS NOT DISTINCT FROM v.periode
             ORDER BY m.id_memoire DESC LIMIT 1)
    RETURNING id_memoire INTO p_memoire;
    RETURN p_memoire;
END $$;

COMMENT ON FUNCTION restaurer_memoire(INTEGER, BIGINT) IS
    'MEM-5 : remet en vigueur une ancienne version d''un étage de la mémoire, en
     gardant ce que l''étage a déjà absorbé. Rien n''est effacé.';

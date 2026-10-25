-- -----------------------------------------------------------------------------
-- Écrire la mémoire d'un lieu                                         (ADR-11)
--
-- Une version de plus ; un texte identique au précédent n'en crée pas
-- (MEM-2). Un texte vide l'efface, sans rien supprimer. Le lieu doit être un
-- de ceux du compte.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ecrire_memoire_lieu(
    p_utilisateur INTEGER,
    p_lieu        INTEGER,
    p_texte       TEXT,
    p_auteur      VARCHAR
) RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE
    v_texte   TEXT := btrim(COALESCE(p_texte, ''));
    v_actuel  memoire_lieu;
    v_id      BIGINT;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM lieux_du_compte(p_utilisateur) l
                    WHERE l.id_lieu_connu = p_lieu) THEN
        PERFORM refus_coach('introuvable', 'Ce lieu n''est pas un de tes lieux connus');
    END IF;
    IF length(v_texte) > 1000 THEN
        PERFORM refus_coach('trop_long', format(
            'La mémoire d''un lieu tient en 1 000 caractères ; celle-ci en a %s. Résume',
            length(v_texte)));
    END IF;

    SELECT * INTO v_actuel FROM memoire_lieu
     WHERE id_utilisateur = p_utilisateur AND id_lieu_connu = p_lieu
     ORDER BY id_memoire_lieu DESC LIMIT 1;
    IF FOUND AND v_actuel.texte = v_texte THEN
        RETURN v_actuel.id_memoire_lieu;
    END IF;
    IF NOT FOUND AND v_texte = '' THEN
        RETURN NULL;
    END IF;

    INSERT INTO memoire_lieu (id_utilisateur, id_lieu_connu, texte, auteur)
    VALUES (p_utilisateur, p_lieu, v_texte, p_auteur)
    RETURNING id_memoire_lieu INTO v_id;
    RETURN v_id;
END $$;

COMMENT ON FUNCTION ecrire_memoire_lieu(INTEGER, INTEGER, TEXT, VARCHAR) IS
    'ADR-11 : une version de plus de la mémoire d''un lieu, 1 000 caractères au plus.';

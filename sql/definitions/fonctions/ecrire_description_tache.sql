-- -----------------------------------------------------------------------------
-- Écrire la description d'une tâche                              (MTA-2, MTA-4)
--
-- Une version de plus ; un texte identique au précédent n'en crée pas. Un
-- texte vide l'efface, sans rien supprimer. C'est HAL qui l'écrit, d'après ce
-- qu'un membre lui dit : il n'y a pas de route pour la changer à la main.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ecrire_description_tache(
    p_tache    INTEGER,
    p_texte    TEXT,
    p_dite_par INTEGER,
    p_appel    BIGINT DEFAULT NULL
) RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE
    v_texte  TEXT := btrim(COALESCE(p_texte, ''));
    v_actuel description_tache;
    v_id     BIGINT;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM tache WHERE id_tache = p_tache AND id_type_tache IS NOT NULL) THEN
        PERFORM refus_coach('introuvable', 'Cette tâche n''existe pas');
    END IF;
    IF length(v_texte) > 1000 THEN
        PERFORM refus_coach('trop_long', format(
            'La description d''une tâche tient en 1 000 caractères ; celle-ci en a %s. Résume',
            length(v_texte)));
    END IF;

    SELECT * INTO v_actuel FROM description_tache
     WHERE id_tache = p_tache
     ORDER BY id_description_tache DESC LIMIT 1;
    IF FOUND AND v_actuel.texte = v_texte THEN
        RETURN v_actuel.id_description_tache;
    END IF;
    IF NOT FOUND AND v_texte = '' THEN
        RETURN NULL;
    END IF;

    INSERT INTO description_tache (id_tache, texte, dite_par, id_appel)
    VALUES (p_tache, v_texte, p_dite_par, p_appel)
    RETURNING id_description_tache INTO v_id;
    RETURN v_id;
END $$;

COMMENT ON FUNCTION ecrire_description_tache(INTEGER, TEXT, INTEGER, BIGINT) IS
    'MTA-2 : une version de plus de la description d''une tâche, 1 000 caractères au plus.';

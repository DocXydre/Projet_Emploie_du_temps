-- -----------------------------------------------------------------------------
-- Retirer un lien entre deux tâches                             (TAC-27, TAC-28)
--
-- Une tâche qui n'a pas de rythme ne vit que de ses liens « Ensuite » : retirer
-- le dernier la ferait disparaître du planning pour toujours, sans un mot. On
-- lui donne d'abord un rythme, ou on l'arrête.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION delier_taches(p_sorte TEXT, p_lien INTEGER)
RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE
    v_suivante INTEGER;
    v_libelle  TEXT;
BEGIN
    IF p_sorte = 'ensuite' THEN
        SELECT e.id_tache_suivante, t.libelle INTO v_suivante, v_libelle
          FROM enchainement e JOIN tache t ON t.id_tache = e.id_tache_suivante
         WHERE e.id_enchainement = p_lien;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Ce lien n''existe plus' USING ERRCODE = 'no_data_found';
        END IF;
        IF EXISTS (SELECT 1 FROM tache WHERE id_tache = v_suivante AND active AND revient = 'apres')
           AND (SELECT count(*) FROM enchainement WHERE id_tache_suivante = v_suivante) = 1 THEN
            RAISE EXCEPTION '« % » ne vient qu''après cette tâche : sans ce lien, elle ne reviendrait plus. Donne-lui un rythme ou arrête-la',
                            v_libelle
                  USING ERRCODE = 'check_violation';
        END IF;
        DELETE FROM enchainement WHERE id_enchainement = p_lien;
    ELSIF p_sorte = 'meme_jour' THEN
        DELETE FROM accompagnement WHERE id_accompagnement = p_lien;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Ce lien n''existe plus' USING ERRCODE = 'no_data_found';
        END IF;
    ELSIF p_sorte = 'vaut_aussi' THEN
        DELETE FROM remplacement WHERE id_remplacement = p_lien;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Ce lien n''existe plus' USING ERRCODE = 'no_data_found';
        END IF;
    ELSE
        RAISE EXCEPTION 'Un lien est « ensuite », « meme_jour » ou « vaut_aussi »'
              USING ERRCODE = 'check_violation';
    END IF;
END $$;

COMMENT ON FUNCTION delier_taches(TEXT, INTEGER) IS
    'TAC-27, TAC-28 : retire un lien. Refuse de retirer le dernier « ensuite »
     d''une tâche active qui ne vit que de lui.';

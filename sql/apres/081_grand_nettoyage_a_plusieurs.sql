-- =============================================================================
-- Rattrapage : le grand nettoyage « à deux » devient une règle a_plusieurs
--
-- La phrase « Se fait à deux, au même moment, sur un créneau où les deux sont
-- libres. S'il n'y en a aucun, le dire aux deux plutôt que de la poser au
-- hasard. », écrite dans la description par la 086, devient une règle typée
-- (RGL-2, membres = 2) et quitte la description. Le reste de la description
-- demeure.
-- =============================================================================
DO $$
DECLARE
    v_phrase CONSTANT TEXT := 'Se fait à deux, au même moment, sur un créneau où les deux sont libres. S''il n''y en a aucun, le dire aux deux plutôt que de la poser au hasard.';
    v_tache INTEGER;
    v_texte TEXT;
BEGIN
    -- 1. Trouver la tâche : par son code dans la base des tests, par sa phrase en production.
    IF to_regprocedure('essais.tache_de(text)') IS NOT NULL THEN
        EXECUTE 'SELECT essais.tache_de(''GRAND_NETTOYAGE'')' INTO v_tache;
    ELSE
        SELECT id_tache INTO v_tache
          FROM v_description_tache
         WHERE position(v_phrase IN texte) > 0
         ORDER BY id_tache
         LIMIT 1;
    END IF;

    -- 2. Sans elle, rien à faire.
    IF v_tache IS NULL THEN
        RETURN;
    END IF;

    -- 3. La règle a_plusieurs.
    PERFORM enregistrer_regle(v_tache, 'a_plusieurs', '{"membres": 2}'::jsonb, 'Le grand nettoyage se fait à deux.', NULL, NULL);

    -- 4. La phrase quitte la description.
    SELECT texte INTO v_texte
      FROM v_description_tache
     WHERE id_tache = v_tache;
    IF FOUND THEN
        v_texte := btrim(regexp_replace(replace(v_texte, v_phrase, ''), ' {2,}', ' ', 'g'));
        PERFORM ecrire_description_tache(v_tache, v_texte, NULL, NULL);
    END IF;
END $$;

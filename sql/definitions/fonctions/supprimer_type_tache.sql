-- -----------------------------------------------------------------------------
-- Supprimer un type de tâche                                           (TAC-26)
--
-- Seulement s'il ne porte plus aucune tâche active : on déplace d'abord ses
-- tâches. Les tâches arrêtées perdent leur type (ON DELETE SET NULL) et gardent
-- leur historique. Le dernier type de ménage reste : c'est celui que prend une
-- tâche créée sans type.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION supprimer_type_tache(p_type INTEGER)
RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE
    v_type   type_tache%ROWTYPE;
    v_actives INTEGER;
BEGIN
    SELECT * INTO v_type FROM type_tache WHERE id_type_tache = p_type;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Ce type de tâche n''existe pas' USING ERRCODE = 'no_data_found';
    END IF;

    SELECT count(*) INTO v_actives FROM tache WHERE id_type_tache = p_type AND active;
    IF v_actives > 0 THEN
        RAISE EXCEPTION '« % » porte encore % tâche(s) : change-les de type d''abord',
                        v_type.libelle, v_actives
              USING ERRCODE = 'check_violation';
    END IF;
    IF v_type.categorie = 'menage'
       AND NOT EXISTS (SELECT 1 FROM type_tache
                        WHERE categorie = 'menage' AND id_type_tache <> p_type) THEN
        RAISE EXCEPTION 'Il faut garder au moins un type de ménage'
              USING ERRCODE = 'check_violation';
    END IF;

    DELETE FROM type_tache WHERE id_type_tache = p_type;
END $$;

COMMENT ON FUNCTION supprimer_type_tache(INTEGER) IS
    'TAC-26 : supprime un type qui ne porte plus de tâche active.';

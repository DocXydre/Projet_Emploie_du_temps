-- -----------------------------------------------------------------------------
-- Supprimer un type de tâche                                           (TAC-26)
--
-- Seulement un type créé par le foyer, et s'il ne porte plus aucune tâche
-- active : on déplace d'abord ses tâches. Ses tâches arrêtées passent à
-- Ménage, avec leur historique : une tâche de la maison a toujours un type.
-- Les cinq types de base ne se suppriment pas (TAC-25).
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
    IF v_type.base IS NOT NULL THEN
        RAISE EXCEPTION '« % » est un type de base : il se renomme et se recolore, mais ne se supprime pas',
                        v_type.libelle
              USING ERRCODE = 'check_violation';
    END IF;

    UPDATE tache
       SET id_type_tache = (SELECT id_type_tache FROM type_tache WHERE base = 'menage')
     WHERE id_type_tache = p_type AND NOT active;

    DELETE FROM type_tache WHERE id_type_tache = p_type;
END $$;

COMMENT ON FUNCTION supprimer_type_tache(INTEGER) IS
    'TAC-26 : supprime un type créé par le foyer qui ne porte plus de tâche active ; ses tâches arrêtées passent à Ménage.';

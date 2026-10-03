-- -----------------------------------------------------------------------------
-- Arrêter une tâche qu'on avait ajoutée                                (TAC-20)
--
-- Seules les tâches ajoutées depuis le bot s'arrêtent ainsi. Les tâches de
-- référence font marcher l'appartement : les retirer reste une décision qu'on
-- prend en base, en connaissance de cause.
--
-- La tâche est désactivée, pas supprimée : ce qui a été fait reste dans
-- l'historique. Ses prévisions s'effacent, et ce qui était déjà annoncé est
-- clos avec sa raison.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION arreter_tache(p_tache INTEGER)
RETURNS BOOLEAN LANGUAGE plpgsql AS $$
BEGIN
    UPDATE tache SET active = FALSE
     WHERE id_tache = p_tache AND ajoutee_par IS NOT NULL AND active;
    IF NOT FOUND THEN
        RETURN FALSE;
    END IF;

    DELETE FROM notification n
     USING occurrence o
     WHERE o.id_occurrence = n.id_occurrence
       AND o.id_tache = p_tache
       AND n.statut = 'a_envoyer';

    DELETE FROM occurrence o
     WHERE o.id_tache = p_tache
       AND o.statut IN ('a_placer', 'planifiee')
       AND NOT EXISTS (SELECT 1 FROM notification n
                        WHERE n.id_occurrence = o.id_occurrence);

    UPDATE occurrence
       SET statut = 'abandonnee', creneau = NULL, motif = 'Tâche arrêtée'
     WHERE id_tache = p_tache
       AND statut IN ('a_placer', 'planifiee', 'notifiee');

    RETURN TRUE;
END $$;

COMMENT ON FUNCTION arreter_tache(INTEGER) IS
    'TAC-20 : désactive une tâche ajoutée depuis le bot et retire ses
     occurrences ouvertes. Rend faux pour une tâche de référence.';

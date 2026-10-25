-- -----------------------------------------------------------------------------
-- Arrêter une tâche                                            (TAC-21, TAC-30)
--
-- Toute tâche de la maison s'arrête, celles d'origine comprises (TAC-29). Elle
-- est désactivée, pas supprimée : elle rejoint les tâches arrêtées, d'où elle
-- se reprend ou s'efface (TAC-31). Ses prévisions s'effacent, et ce qui était
-- déjà annoncé est clos avec sa raison.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION arreter_tache(p_tache INTEGER)
RETURNS BOOLEAN LANGUAGE plpgsql AS $$
BEGIN
    UPDATE tache SET active = FALSE, arretee_le = now()
     WHERE id_tache = p_tache AND id_type_tache IS NOT NULL AND active;
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
    'TAC-21 : arrête une tâche de la maison et retire ses occurrences
     ouvertes. Rend faux pour une tâche déjà arrêtée ou pour le sport.';

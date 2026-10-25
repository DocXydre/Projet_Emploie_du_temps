-- -----------------------------------------------------------------------------
-- Une occurrence hérite de la nature de sa tâche                          (TAC-2)
--
-- Dénormalisation assumée : une contrainte d'exclusion ne sait pas lire une
-- table liée. Le drapeau du rappel conditionne le chevauchement (TAC-6), il
-- doit donc vivre sur la ligne. La tâche le calcule de sa plage horaire.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_occurrence_heriter_tache() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
DECLARE t RECORD;
BEGIN
    SELECT rappel_journee, id_utilisateur_defaut
      INTO t FROM tache WHERE id_tache = NEW.id_tache;

    NEW.rappel_journee := t.rappel_journee;

    -- L'assignation par défaut ne s'applique qu'aux occurrences créées par le
    -- système. Une création manuelle peut laisser l'assigné à NULL : c'est ce
    -- qui permet à un refus de libérer la tâche pour l'autre personne.
    IF NEW.id_utilisateur IS NULL AND NEW.origine <> 'manuelle' THEN
        NEW.id_utilisateur := t.id_utilisateur_defaut;
    END IF;

    RETURN NEW;
END $$;

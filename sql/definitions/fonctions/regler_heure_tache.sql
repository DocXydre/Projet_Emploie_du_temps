-- -----------------------------------------------------------------------------
-- Changer l'heure d'une tâche                                   (TAC-21, TAC-23)
--
-- Passer d'un rappel de journée à une heure, ou l'inverse, change la nature de
-- la tâche (TAC-2), et ses occurrences portent cette nature sur leur ligne : la
-- contrainte de chevauchement ne sait pas lire la tâche. Celles qui ne sont ni
-- faites, ni annoncées, ni épinglées suivent donc, et repassent à placer.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION regler_heure_tache(p_tache     INTEGER,
                                              p_heure_min TIME,
                                              p_heure_max TIME)
RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE
    t       tache%ROWTYPE;
    v_rappel BOOLEAN := p_heure_min IS NULL;
BEGIN
    SELECT * INTO t FROM tache WHERE id_tache = p_tache;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Tâche % inconnue', p_tache USING ERRCODE = 'no_data_found';
    END IF;
    IF t.categorie = 'sport' THEN
        RAISE EXCEPTION 'L''heure d''une séance se règle dans Sport'
              USING ERRCODE = 'check_violation';
    END IF;
    IF t.requiert_les_deux AND v_rappel THEN
        RAISE EXCEPTION 'Une tâche à deux a une heure : sans elle, rien ne dit que vous serez là ensemble'
              USING ERRCODE = 'check_violation';
    END IF;

    PERFORM verifier_plage_horaire(p_heure_min, p_heure_max, t.duree_minutes);

    IF t.rappel_journee = v_rappel
       AND t.heure_min IS NOT DISTINCT FROM p_heure_min
       AND t.heure_max IS NOT DISTINCT FROM p_heure_max THEN
        RETURN;
    END IF;

    UPDATE tache
       SET rappel_journee = v_rappel, heure_min = p_heure_min, heure_max = p_heure_max
     WHERE id_tache = p_tache;

    UPDATE occurrence
       SET rappel_journee = v_rappel,
           creneau        = NULL,
           statut         = 'a_placer',
           fenetre        = fenetre_pour(v_rappel, lower(fenetre), upper(fenetre)),
           motif          = 'Heure changée, à replacer'
     WHERE id_tache = p_tache
       AND statut IN ('a_placer', 'planifiee')
       AND NOT epinglee;
END $$;

COMMENT ON FUNCTION regler_heure_tache(INTEGER, TIME, TIME) IS
    'TAC-23 : donne à une tâche une heure, une plage, ou aucune, et remet à
     placer ses occurrences ni faites, ni annoncées, ni épinglées.';

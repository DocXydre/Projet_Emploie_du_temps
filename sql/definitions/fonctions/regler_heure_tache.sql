-- -----------------------------------------------------------------------------
-- Changer l'heure d'une tâche                                   (TAC-21, TAC-23)
--
-- Passer d'un rappel de journée à une heure, ou l'inverse, change la nature de
-- la tâche (TAC-2), et ses occurrences portent cette nature sur leur ligne : la
-- contrainte de chevauchement ne sait pas lire la tâche. Celles qui ne sont ni
-- faites, ni annoncées, ni épinglées suivent donc, et repassent à placer.
--
-- La durée peut changer en même temps, dans la même mise à jour : « à 18h30 »
-- est une plage de la longueur de la tâche, et changer l'une sans l'autre
-- butterait sur `tache_plage_contient_la_duree`.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION regler_heure_tache(p_tache         INTEGER,
                                              p_heure_min     TIME,
                                              p_heure_max     TIME,
                                              p_duree_minutes INTEGER DEFAULT NULL)
RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE
    t        tache%ROWTYPE;
    v_rappel BOOLEAN := p_heure_min IS NULL;
    v_duree  INTEGER;
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

    v_duree := COALESCE(p_duree_minutes, t.duree_minutes);
    IF v_duree < 1 OR v_duree > 480 THEN
        RAISE EXCEPTION 'La durée va de 1 minute à 8 heures'
              USING ERRCODE = 'check_violation';
    END IF;
    PERFORM verifier_plage_horaire(p_heure_min, p_heure_max, v_duree);

    IF t.rappel_journee = v_rappel
       AND t.heure_min IS NOT DISTINCT FROM p_heure_min
       AND t.heure_max IS NOT DISTINCT FROM p_heure_max
       AND t.duree_minutes = v_duree THEN
        RETURN;
    END IF;

    UPDATE tache
       SET rappel_journee = v_rappel, heure_min = p_heure_min, heure_max = p_heure_max,
           duree_minutes = v_duree
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

COMMENT ON FUNCTION regler_heure_tache(INTEGER, TIME, TIME, INTEGER) IS
    'TAC-23 : donne à une tâche une heure, une plage, ou aucune, et sa durée
     avec, et remet à placer ses occurrences ni faites, ni annoncées, ni
     épinglées.';

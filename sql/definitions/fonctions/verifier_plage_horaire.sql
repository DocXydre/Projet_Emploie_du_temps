-- -----------------------------------------------------------------------------
-- Une plage horaire tient dans la journée et contient la tâche         (TAC-23)
--
-- Sans heure : les deux bornes vides. « À 18h30 » : la fin vaut le début plus
-- la durée. « Entre 18h et 21h » : la plage est au moins aussi longue que la
-- tâche. La contrainte `tache_plage_contient_la_duree` dit la même chose ; ici
-- le refus arrive avant, avec une phrase.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION verifier_plage_horaire(p_heure_min     TIME,
                                                  p_heure_max     TIME,
                                                  p_duree_minutes INTEGER)
RETURNS VOID LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
    IF (p_heure_min IS NULL) <> (p_heure_max IS NULL) THEN
        RAISE EXCEPTION 'Une plage horaire a un début et une fin'
              USING ERRCODE = 'check_violation';
    END IF;
    IF p_heure_min IS NULL THEN
        RETURN;
    END IF;
    IF p_heure_max <= p_heure_min THEN
        RAISE EXCEPTION 'La plage ne passe pas minuit : sa fin suit son début'
              USING ERRCODE = 'check_violation';
    END IF;
    IF p_heure_max - p_heure_min < make_interval(mins => p_duree_minutes) THEN
        RAISE EXCEPTION 'La plage est plus courte que la tâche (% min)', p_duree_minutes
              USING ERRCODE = 'check_violation';
    END IF;
END $$;

COMMENT ON FUNCTION verifier_plage_horaire(TIME, TIME, INTEGER) IS
    'TAC-23 : refuse une plage à moitié donnée, qui passe minuit, ou plus courte
     que la tâche.';

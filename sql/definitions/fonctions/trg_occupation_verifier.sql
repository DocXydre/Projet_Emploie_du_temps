-- -----------------------------------------------------------------------------
-- Un créneau pris tombe sur le jour d'une tâche décrite                 (VER-3)
--
-- Un cours ajouté samedi : la tâche que HAL y avait mise, épinglée, ne bouge
-- pas toute seule ; elle entre dans la file, et HAL la relit. Par ligne, mais
-- sans rien lire quand aucune tâche n'est décrite.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_occupation_verifier() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
DECLARE
    v_periode TSTZRANGE;
    v_compte  INTEGER;
    o         RECORD;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM description_tache) THEN
        RETURN NULL;
    END IF;
    FOREACH v_periode IN ARRAY ARRAY[CASE WHEN TG_OP <> 'INSERT' THEN OLD.periode END,
                                     CASE WHEN TG_OP <> 'DELETE' THEN NEW.periode END] LOOP
        CONTINUE WHEN v_periode IS NULL;
        v_compte := CASE WHEN TG_OP = 'DELETE' THEN OLD.id_utilisateur ELSE NEW.id_utilisateur END;
        FOR o IN
            SELECT oc.id_occurrence
              FROM occurrence oc
             WHERE oc.statut IN ('a_placer', 'planifiee', 'notifiee')
               AND (oc.id_utilisateur IS NULL OR oc.id_utilisateur = v_compte)
               AND tstzrange(debut_jour(jour_de(lower(COALESCE(oc.creneau, oc.fenetre)))),
                             debut_jour(jour_de(lower(COALESCE(oc.creneau, oc.fenetre))) + 1), '[)')
                   && v_periode
        LOOP
            PERFORM noter_verification(o.id_occurrence, NULL, 'occupation');
        END LOOP;
    END LOOP;
    RETURN NULL;
END $$;

COMMENT ON FUNCTION trg_occupation_verifier() IS
    'VER-3 : une occupation ajoutée, changée ou retirée fait relire les occurrences décrites de ce jour-là.';

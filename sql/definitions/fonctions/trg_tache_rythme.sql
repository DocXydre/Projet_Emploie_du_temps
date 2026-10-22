-- -----------------------------------------------------------------------------
-- La périodicité d'une tâche à rythme                                   (CND-4)
--
-- Une tâche à rythme garde des colonnes de périodicité remplies, que d'autres
-- fonctions lisent : deux fois par semaine, c'est tous les 3 à 4 jours ; une
-- fois par mois, tous les 30 jours.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_tache_rythme()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    v_jours INTEGER;
BEGIN
    IF NEW.rythme_nombre IS NOT NULL THEN
        v_jours := CASE NEW.rythme_periode WHEN 'semaine' THEN 7 ELSE 30 END;
        NEW.periodicite_min_jours := GREATEST(1, v_jours / NEW.rythme_nombre);
        NEW.periodicite_max_jours := GREATEST(NEW.periodicite_min_jours,
                                              ceil(v_jours::NUMERIC / NEW.rythme_nombre)::INTEGER);
    END IF;
    RETURN NEW;
END $$;

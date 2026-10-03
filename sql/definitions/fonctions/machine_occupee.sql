-- -----------------------------------------------------------------------------
-- La machine à laver est une ressource unique de l'appartement           (UNI-12)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION machine_occupee(p_jour DATE, p_sauf INTEGER DEFAULT NULL)
RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
    SELECT EXISTS (
        SELECT 1 FROM occurrence o
         WHERE o.utilise_machine
           AND o.creneau IS NOT NULL
           AND o.statut IN ('planifiee', 'notifiee')
           AND jour_de(lower(o.creneau)) = p_jour
           AND (p_sauf IS NULL OR o.id_occurrence <> p_sauf)
    );
$$;

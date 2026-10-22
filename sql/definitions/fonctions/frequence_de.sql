-- -----------------------------------------------------------------------------
-- La fréquence d'une tâche un jour donné                         (CND-4, CND-7)
--
-- Celle d'une règle active dont la période contient le jour, la plus récente
-- s'il y en a deux ; sinon celle de la tâche. Une périodicité en jours, ou un
-- rythme : N fois par semaine ou par mois.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION frequence_de(p_tache INTEGER, p_jour DATE)
RETURNS TABLE (periodicite_min_jours INTEGER, periodicite_max_jours INTEGER,
               rythme_nombre INTEGER, rythme_periode TEXT, rythme_moment TEXT)
LANGUAGE sql STABLE AS $$
    SELECT f.pmin, f.pmax, f.nombre, f.periode, f.moment
      FROM (SELECT 1 AS rang, r.creee_le,
                   r.periodicite_min_jours AS pmin, r.periodicite_max_jours AS pmax,
                   r.rythme_nombre::INTEGER AS nombre, r.rythme_periode::TEXT AS periode,
                   'indifferent'::TEXT AS moment
              FROM regle_tache r
             WHERE r.id_tache = p_tache
               AND r.etat = 'active'
               AND (r.periodicite_min_jours IS NOT NULL OR r.rythme_nombre IS NOT NULL)
               AND dans_validite(r.validite, r.chaque_annee, p_jour)
            UNION ALL
            SELECT 2, NULL,
                   t.periodicite_min_jours, t.periodicite_max_jours,
                   t.rythme_nombre::INTEGER, t.rythme_periode::TEXT, t.rythme_moment::TEXT
              FROM tache t
             WHERE t.id_tache = p_tache) f
     ORDER BY f.rang, f.creee_le DESC NULLS LAST
     LIMIT 1;
$$;

COMMENT ON FUNCTION frequence_de(INTEGER, DATE) IS
    'CND-4, CND-7 : la périodicité ou le rythme en vigueur pour la tâche ce jour-là.';

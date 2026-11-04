-- -----------------------------------------------------------------------------
-- Ce que quelqu'un a à faire sur une période                           (PLA-16)
--
-- Les tâches partagées seulement, faites ou à faire : c'est sur elles que le
-- mode allégé déplace la part de chacun. Une tâche réservée à quelqu'un lui
-- reste, et n'entre pas dans le compte.
-- Une tâche à plusieurs (des participants, RGL-7) n'y entre pas non plus.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION charge_sur(p_utilisateur INTEGER, p_periode TSTZRANGE)
RETURNS INTEGER LANGUAGE sql STABLE AS $$
    SELECT COALESCE(sum(t.duree_minutes), 0)::INTEGER
      FROM occurrence o
      JOIN tache t ON t.id_tache = o.id_tache
     WHERE o.id_utilisateur = p_utilisateur
       AND t.id_type_tache IS NOT NULL
       AND t.id_utilisateur_defaut IS NULL
       -- RGL-7 : une tâche à plusieurs ne se répartit pas, le mode allégé n'y change rien.
       AND NOT EXISTS (SELECT 1 FROM occurrence_participant p
                        WHERE p.id_occurrence = o.id_occurrence)
       AND o.origine NOT IN ('depart', 'retour')
       AND o.statut IN ('a_placer', 'planifiee', 'notifiee', 'faite')
       AND p_periode @> COALESCE(o.date_faite, lower(o.creneau), lower(o.fenetre));
$$;

COMMENT ON FUNCTION charge_sur(INTEGER, TSTZRANGE) IS
    'PLA-16 : minutes de tâches partagées, faites ou à faire, sur une période. Hors tâches à plusieurs (RGL-7).';

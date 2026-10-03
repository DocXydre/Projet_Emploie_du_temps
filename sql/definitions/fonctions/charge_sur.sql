-- -----------------------------------------------------------------------------
-- Ce que quelqu'un a à faire sur une période                           (PLA-16)
--
-- Les tâches partagées seulement, faites ou à faire : c'est sur elles que le
-- mode allégé déplace la part de chacun. Une tâche réservée à quelqu'un lui
-- reste, et n'entre pas dans le compte.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION charge_sur(p_utilisateur INTEGER, p_periode TSTZRANGE)
RETURNS INTEGER LANGUAGE sql STABLE AS $$
    SELECT COALESCE(sum(t.duree_minutes), 0)::INTEGER
      FROM occurrence o
      JOIN tache t ON t.id_tache = o.id_tache
     WHERE o.id_utilisateur = p_utilisateur
       AND t.categorie <> 'sport'
       AND NOT t.requiert_les_deux
       AND t.id_utilisateur_defaut IS NULL
       AND o.origine NOT IN ('depart', 'retour')
       AND o.statut IN ('a_placer', 'planifiee', 'notifiee', 'faite')
       AND p_periode @> COALESCE(o.date_faite, lower(o.creneau), lower(o.fenetre));
$$;

COMMENT ON FUNCTION charge_sur(INTEGER, TSTZRANGE) IS
    'PLA-16 : minutes de tâches partagées, faites ou à faire, sur une période.';

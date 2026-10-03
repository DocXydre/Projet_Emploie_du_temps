CREATE OR REPLACE FUNCTION charge_domestique(p_utilisateur INTEGER) RETURNS INTEGER
LANGUAGE sql STABLE AS $$
    -- PLA-10 : le sport est personnel, il n'entre pas dans la balance.
    --
    -- Une tâche à deux non plus : le grand nettoyage dure deux heures et se
    -- fait ensemble. Le compter chez celui à qui il est nominalement assigné
    -- lui donnait deux heures d'avance imaginaire, et lui épargnait tout le
    -- reste pendant des semaines.
    SELECT COALESCE(sum(t.duree_minutes), 0)::INTEGER
      FROM occurrence o
      JOIN tache t ON t.id_tache = o.id_tache
     WHERE o.id_utilisateur = p_utilisateur
       AND t.categorie <> 'sport'
       AND NOT t.requiert_les_deux
       AND o.statut IN ('a_placer', 'planifiee', 'notifiee');
$$;

COMMENT ON FUNCTION charge_domestique IS
    'Minutes de tâches domestiques encore à faire, sport et tâches à deux
     exclus, pour équilibrer la répartition (PLA-10, PLA-12).';

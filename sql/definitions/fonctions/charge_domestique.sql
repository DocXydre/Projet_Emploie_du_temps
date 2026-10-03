CREATE OR REPLACE FUNCTION charge_domestique(p_utilisateur INTEGER) RETURNS INTEGER
LANGUAGE sql STABLE AS $$
    -- PLA-10 : le sport est personnel, il n'entre pas dans la balance.
    --
    -- Une tâche à deux non plus : le grand nettoyage dure deux heures et se
    -- fait ensemble. Le compter chez celui à qui il est nominalement assigné
    -- lui donnait deux heures d'avance imaginaire, et lui épargnait tout le
    -- reste pendant des semaines.
    --
    -- PLA-15 : ce qu'on fait seul parce que l'autre est parti ne compte pas non
    -- plus, ni ce qu'on fait en partant ou en rentrant. Celui qui reste vit
    -- dans l'appartement, il est normal qu'il s'en occupe. Compter ces tâches
    -- faisait passer celui qui reste pour débordé, et celui qui rentre
    -- récupérait tout le ménage de la semaine suivante.
    SELECT COALESCE(sum(t.duree_minutes), 0)::INTEGER
      FROM occurrence o
      JOIN tache t ON t.id_tache = o.id_tache
     WHERE o.id_utilisateur = p_utilisateur
       AND t.categorie <> 'sport'
       AND NOT t.requiert_les_deux
       AND o.statut IN ('a_placer', 'planifiee', 'notifiee')
       AND o.origine NOT IN ('depart', 'retour')
       AND NOT seul_ce_jour(p_utilisateur, jour_de(lower(COALESCE(o.creneau, o.fenetre))));
$$;

COMMENT ON FUNCTION charge_domestique IS
    'Minutes de tâches domestiques encore à faire, pour équilibrer la
     répartition. Hors sport, tâches à deux, tâches de départ et de retour, et
     jours où l''autre est absent (PLA-10, PLA-12, PLA-15).';

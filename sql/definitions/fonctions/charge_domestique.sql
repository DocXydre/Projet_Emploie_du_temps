CREATE OR REPLACE FUNCTION charge_domestique(p_utilisateur INTEGER) RETURNS INTEGER
LANGUAGE sql STABLE AS $$
    -- PLA-10 : le sport est personnel, il n'entre pas dans la balance.
    --
    -- PLA-15 : ce qu'on fait seul parce que l'autre est parti ne compte pas non
    -- plus, ni les tâches de départ et de retour d'avant octobre 2026. Celui qui reste vit
    -- dans l'appartement, il est normal qu'il s'en occupe. Compter ces tâches
    -- faisait passer celui qui reste pour débordé, et celui qui rentre
    -- récupérait tout le ménage de la semaine suivante.
    --
    -- PLA-16 : même raison pour les jours de mode allégé. La répartition y est
    -- inégale parce qu'on l'a voulu, elle ne se rattrape pas ensuite.
    SELECT COALESCE(sum(t.duree_minutes), 0)::INTEGER
      FROM occurrence o
      JOIN tache t ON t.id_tache = o.id_tache
     CROSS JOIN LATERAL (
           SELECT jour_de(lower(COALESCE(o.creneau, o.fenetre))) AS jour,
                  tstzrange(debut_jour(jour_de(lower(COALESCE(o.creneau, o.fenetre)))),
                            debut_jour(jour_de(lower(COALESCE(o.creneau, o.fenetre))) + 1),
                            '[)') AS plage) j
     WHERE o.id_utilisateur = p_utilisateur
       AND t.id_type_tache IS NOT NULL
       AND o.statut IN ('a_placer', 'planifiee', 'notifiee')
       AND o.origine NOT IN ('depart', 'retour')
       -- Les deux exceptions ne se vérifient que si une absence ou un mode
       -- allégé touche ce jour-là. Cette fonction est appelée à chaque tâche
       -- placée : sans ce garde-fou, le cas ordinaire, où personne n'est parti,
       -- payait deux vérifications par occurrence pour rien.
       AND NOT CASE WHEN EXISTS (SELECT 1 FROM absence a
                                  WHERE a.id_utilisateur <> p_utilisateur
                                    AND a.periode @> j.plage)
                    THEN seul_ce_jour(p_utilisateur, j.jour) ELSE FALSE END
       AND NOT CASE WHEN EXISTS (SELECT 1 FROM allegement g WHERE g.periode && j.plage)
                    THEN jour_allege(j.jour) ELSE FALSE END;
$$;

COMMENT ON FUNCTION charge_domestique IS
    'Minutes de tâches domestiques encore à faire, pour équilibrer la
     répartition. Hors sport, tâches de départ et de retour,
     jours où l''autre est absent et jours de mode allégé (PLA-10, PLA-12,
     PLA-15, PLA-16).';

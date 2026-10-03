-- -----------------------------------------------------------------------------
-- Qui l'a faite en dernier                                             (PLA-12)
--
-- La dernière occurrence attribuée, faite ou seulement prévue. Prévue compte
-- aussi : pendant un placement, les occurrences d'une même tâche se suivent, et
-- c'est précisément entre elles qu'on veut alterner.
--
-- PLA-15 : une tâche faite seul, parce que l'autre était parti, n'est pas un
-- tour. Sans cette exception, celui qui rentre trouverait chaque tâche « à son
-- tour », puisque l'autre les a toutes faites en dernier. Le tour reprend donc
-- là où il s'était arrêté avant l'absence. Les tâches de départ et de retour,
-- qui viennent en plus, n'en sont pas non plus.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION dernier_a_faire(p_tache INTEGER) RETURNS INTEGER
LANGUAGE sql STABLE AS $$
    SELECT o.id_utilisateur
      FROM occurrence o
     WHERE o.id_tache = p_tache
       AND o.id_utilisateur IS NOT NULL
       AND o.statut IN ('faite', 'planifiee', 'notifiee')
       AND o.origine NOT IN ('depart', 'retour')
       -- Vérifié seulement si quelqu'un d'autre était absent à ce moment-là.
       AND NOT CASE WHEN EXISTS (
                        SELECT 1 FROM absence a
                         WHERE a.id_utilisateur <> o.id_utilisateur
                           AND a.periode @> COALESCE(o.date_faite, lower(o.creneau),
                                                     upper(o.fenetre)))
                    THEN seul_ce_jour(o.id_utilisateur,
                                      jour_de(COALESCE(o.date_faite, lower(o.creneau),
                                                       upper(o.fenetre))))
                    ELSE FALSE END
     ORDER BY COALESCE(o.date_faite, lower(o.creneau), upper(o.fenetre)) DESC,
              o.id_occurrence DESC
     LIMIT 1;
$$;

COMMENT ON FUNCTION dernier_a_faire IS
    'La personne de la dernière occurrence de cette tâche, faite ou prévue.
     C''est elle que le tour suivant évite (PLA-12). Ce qui a été fait seul
     pendant l''absence de l''autre n''est pas un tour (PLA-15).';

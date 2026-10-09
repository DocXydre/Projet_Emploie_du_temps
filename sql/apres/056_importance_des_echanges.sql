-- MEM-8 : l'importance des échanges écrits avant qu'elle existe.
UPDATE echange e
   SET importance = importance_operation(e.operation, e.moment)
 WHERE e.operation IS NOT NULL AND e.auteur IN ('coach', 'systeme');
UPDATE echange e SET importance = 2
 WHERE e.operation IS NULL AND e.moment = 'signalement' AND e.importance < 2;
UPDATE echange u
   SET importance = r.importance
  FROM echange r
 WHERE u.auteur = 'utilisateur' AND r.auteur IN ('coach', 'systeme')
   AND r.id_utilisateur = u.id_utilisateur
   AND r.id_echange = (SELECT min(x.id_echange) FROM echange x
                        WHERE x.id_utilisateur = u.id_utilisateur
                          AND x.id_echange > u.id_echange
                          AND x.auteur IN ('coach', 'systeme'))
   AND u.importance < r.importance;

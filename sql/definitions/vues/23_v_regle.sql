-- ----
-- RGL-9, RGL-11 : les règles typées en vigueur de chaque tâche, avec leur phrase et leur sorte.
-- en_vigueur est faux tant que la tâche est arrêtée : la règle revient avec elle.
-- Les règles retirées, remplacées ou en échec n'y sont pas ; celles d'une source et les règles SQL n'y sont pas non plus
-- (jointure sur sorte_regle et tache).
CREATE VIEW v_regle AS
SELECT r.id_regle, r.id_tache, r.sorte, s.libelle AS sorte_libelle, r.parametres, r.phrase, r.dite_par, u.nom AS dite_par_nom, r.creee_le, t.active AS en_vigueur
  FROM regle r
  JOIN sorte_regle s ON s.code = r.sorte
  JOIN tache t ON t.id_tache = r.id_tache
  LEFT JOIN utilisateur u ON u.id_utilisateur = r.dite_par
 WHERE r.etat = 'active';

COMMENT ON VIEW v_regle IS 'RGL-9, RGL-11 : les règles typées en vigueur de chaque tâche, avec leur phrase et leur sorte. en_vigueur est faux tant que la tâche est arrêtée : la règle revient avec elle.';

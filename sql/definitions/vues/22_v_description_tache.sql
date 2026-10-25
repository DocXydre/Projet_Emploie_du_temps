-- -----------------------------------------------------------------------------
-- La description en vigueur de chaque tâche                      (MTA-4, MTA-7)
--
-- La dernière version, avec qui l'a dite. Une description effacée garde sa
-- ligne, vide : la vue ne la rend pas.
-- -----------------------------------------------------------------------------
CREATE VIEW v_description_tache AS
SELECT d.id_tache, d.id_description_tache, d.texte, d.dite_par,
       u.nom AS dite_par_nom, d.quand
  FROM (SELECT DISTINCT ON (id_tache) *
          FROM description_tache
         ORDER BY id_tache, id_description_tache DESC) d
  LEFT JOIN utilisateur u ON u.id_utilisateur = d.dite_par
 WHERE d.texte <> '';

COMMENT ON VIEW v_description_tache IS
    'MTA-4 : la description en vigueur de chaque tâche décrite, et qui l''a dite.';

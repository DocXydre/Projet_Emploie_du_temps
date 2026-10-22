-- La version en vigueur de chaque étage de la mémoire du foyer (HDF-4) : la
-- dernière écrite, pour un foyer, un étage et une période.
CREATE VIEW v_memoire_foyer AS
SELECT DISTINCT ON (m.id_foyer, m.niveau, m.periode)
       m.id_memoire, m.id_foyer, m.niveau, m.periode, m.texte, m.auteur, m.id_auteur,
       u.nom AS nom_auteur, m.quand,
       char_length(m.texte)     AS longueur,
       limite_memoire(m.niveau) AS limite
  FROM memoire_foyer m
  LEFT JOIN utilisateur u ON u.id_utilisateur = m.id_auteur
 ORDER BY m.id_foyer, m.niveau, m.periode, m.id_memoire DESC;

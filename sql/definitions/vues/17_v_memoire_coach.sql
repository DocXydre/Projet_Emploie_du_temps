-- La version en vigueur de chaque étage de la mémoire du coach (MEM-2) : la
-- dernière écrite, pour un compte, un étage et une période.
CREATE VIEW v_memoire_coach AS
SELECT DISTINCT ON (m.id_utilisateur, m.niveau, m.periode)
       m.id_memoire, m.id_utilisateur, m.niveau, m.periode, m.texte, m.auteur,
       m.couvre_jusqu_au, m.quand,
       char_length(m.texte)          AS longueur,
       limite_memoire(m.niveau)      AS limite
  FROM memoire_coach m
 ORDER BY m.id_utilisateur, m.niveau, m.periode, m.id_memoire DESC;

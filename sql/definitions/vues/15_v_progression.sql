CREATE VIEW v_progression AS
SELECT o.id_utilisateur,
       ss.id_exercice,
       e.code,
       e.libelle,
       lundi_de(jour_de(ss.saisie_le))          AS lundi,
       max(ss.charge_kg)                        AS meilleure_charge,
       max(ss.repetitions)                      AS meilleures_repetitions,
       sum(ss.charge_kg * ss.repetitions)       AS volume,
       count(*)::INTEGER                        AS series,
       sum(ss.duree_secondes)                   AS duree_secondes,
       sum(ss.distance_m)                       AS distance_m
  FROM serie_saisie ss
  JOIN occurrence o ON o.id_occurrence = ss.id_occurrence
  JOIN exercice e   ON e.id_exercice = ss.id_exercice
 GROUP BY o.id_utilisateur, ss.id_exercice, e.code, e.libelle, lundi_de(jour_de(ss.saisie_le));

COMMENT ON VIEW v_progression IS
    'OBJ-1 : par exercice et par semaine, la meilleure charge, le volume et le
     nombre de séries saisies. La charge est commune aux deux côtés (SEC-2).';

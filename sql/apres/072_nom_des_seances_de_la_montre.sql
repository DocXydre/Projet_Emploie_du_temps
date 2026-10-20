-- SAN-4 : les séances libres nées de la montre avant ce rattrapage portaient
-- le type brut (« running »). Elles prennent leur nom français. Seules celles
-- qui ont encore ce type brut changent : un nom donné depuis à la main reste.
UPDATE seance se
   SET type_seance = COALESCE(nom_seance_montre(a.type, a.details -> 'interieur' = 'true'),
                              'libre')
  FROM activite_sante a
 WHERE a.id_occurrence = se.id_occurrence
   AND a.doublon_de IS NULL
   AND se.libre
   AND se.type_seance = left(a.type, 40);

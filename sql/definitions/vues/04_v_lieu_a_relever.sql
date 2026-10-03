-- -----------------------------------------------------------------------------
-- Lieux à relever
-- -----------------------------------------------------------------------------
CREATE VIEW v_lieu_a_relever AS
SELECT id_lieu, code, libelle, url_horaires, configuration,
       horaires_releves_le,
       (SELECT count(*) FROM ouverture o WHERE o.id_lieu = l.id_lieu) AS creneaux,
       horaires_releves_le IS NULL
       OR horaires_releves_le < now() - INTERVAL '2 days' AS a_relever
  FROM lieu_sport l
 WHERE url_horaires IS NOT NULL;

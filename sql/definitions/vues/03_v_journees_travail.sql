-- -----------------------------------------------------------------------------
-- Journées de travail à venir : matière première de la projection de stock
-- -----------------------------------------------------------------------------
CREATE VIEW v_journees_travail AS
SELECT DISTINCT
    o.id_utilisateur,
    (lower(o.periode) AT TIME ZONE 'Europe/Paris')::DATE AS jour,
    min(lower(o.periode))                                AS debut_premier_shift
FROM occupation o
WHERE o.type = 'travail'
  AND upper(o.periode) > now()
GROUP BY o.id_utilisateur, (lower(o.periode) AT TIME ZONE 'Europe/Paris')::DATE
ORDER BY jour;

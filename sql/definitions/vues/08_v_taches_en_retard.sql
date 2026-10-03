CREATE VIEW v_taches_en_retard AS
SELECT * FROM v_occurrence WHERE en_retard ORDER BY priorite, echeance_max;

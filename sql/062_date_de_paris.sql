-- =============================================================================
-- 062 : « pas dans le futur », à l'heure de Paris                     (MES-2)
--
-- Rejouable.
--
-- La base vit en UTC. Une mesure saisie entre minuit et deux heures du matin
-- porte la date de Paris, qui a déjà un jour d'avance sur CURRENT_DATE : la
-- contrainte la prenait pour une mesure du futur et la refusait.
-- =============================================================================

ALTER TABLE mesure DROP CONSTRAINT IF EXISTS mesure_date_mesure_check;
ALTER TABLE mesure ADD CONSTRAINT mesure_date_mesure_check
    CHECK (date_mesure <= (now() AT TIME ZONE 'Europe/Paris')::DATE);
ALTER TABLE mesure ALTER COLUMN date_mesure SET DEFAULT (now() AT TIME ZONE 'Europe/Paris')::DATE;

ALTER TABLE depistage DROP CONSTRAINT IF EXISTS depistage_date_reponse_check;
ALTER TABLE depistage ADD CONSTRAINT depistage_date_reponse_check
    CHECK (date_reponse <= (now() AT TIME ZONE 'Europe/Paris')::DATE);
ALTER TABLE depistage ALTER COLUMN date_reponse SET DEFAULT (now() AT TIME ZONE 'Europe/Paris')::DATE;

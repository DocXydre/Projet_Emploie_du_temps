-- =============================================================================
-- 063 : le moment « changement »                              (COA-32, COA-33)
--
-- Rejouable.
--
-- « Demander un changement », sur une séance, une course ou la semaine, ouvre
-- HAL avec cet élément joint. C'est un moment à part : HAL propose, rien ne
-- change sans validation. Ses appels et ses échanges portent ce moment.
-- =============================================================================

ALTER TABLE appel_coach DROP CONSTRAINT IF EXISTS appel_coach_moment_check;
ALTER TABLE appel_coach ADD CONSTRAINT appel_coach_moment_check
    CHECK (moment IN ('faisabilite', 'plan', 'revision', 'synthese', 'bilan',
                      'signalement', 'chat', 'changement'));

ALTER TABLE echange DROP CONSTRAINT IF EXISTS echange_moment_check;
ALTER TABLE echange ADD CONSTRAINT echange_moment_check
    CHECK (moment IN ('faisabilite', 'plan', 'revision', 'synthese', 'bilan',
                      'signalement', 'chat', 'changement'));

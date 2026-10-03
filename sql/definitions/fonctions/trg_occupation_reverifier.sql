-- -----------------------------------------------------------------------------
-- À chaque changement de l'emploi du temps                              (WKD-9)
--
-- Un trigger, et non un appel dans chaque chemin qui écrit une occupation. La
-- collecte, le bot, l'API et une correction faite à la main en SQL passent
-- tous par la table : c'est le seul endroit où l'on est sûr de ne rien oublier.
-- Par instruction et non par ligne, pour ne pas revérifier trois cents fois
-- une collecte qui tient en une requête.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_occupation_reverifier() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
    PERFORM reverifier_propositions();
    RETURN NULL;
END $$;

-- -----------------------------------------------------------------------------
-- Le journal n'est pas une archive                                      (JRN-8)
--
-- Il dit quand l'appartement était vide et qui a fait quoi. Trois mois
-- suffisent pour répondre à « pourquoi ça a fait ça ? », et rien ne justifie
-- de le garder au-delà.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION purger_journal(p_jours INTEGER DEFAULT 90)
RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE
    v_purges INTEGER;
BEGIN
    DELETE FROM evenement WHERE quand < now() - make_interval(days => p_jours);
    GET DIAGNOSTICS v_purges = ROW_COUNT;
    RETURN v_purges;
END $$;

COMMENT ON FUNCTION purger_journal(INTEGER) IS
    'JRN-8 : supprime les événements de plus de 90 jours. Appelée chaque nuit.';

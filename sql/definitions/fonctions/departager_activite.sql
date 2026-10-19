-- -----------------------------------------------------------------------------
-- Une même séance venue de deux applications                            (SAN-15)
--
-- Santé reçoit parfois la même course deux fois : de la montre, et de Strava ou
-- d'une autre appli. Deux séances du même compte et de la même discipline qui
-- se recouvrent sur plus de la moitié de la plus courte sont la même. Celle de
-- la montre compte ; entre deux montres ou deux applis, la première reçue.
-- L'autre garde tout son détail, mais pointe vers celle qui compte, et perd sa
-- séance prévue au profit de celle-ci. Rend la séance qui compte.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION departager_activite(p_activite BIGINT)
RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE
    a            RECORD;
    r            RECORD;
BEGIN
    SELECT ac.*, activite_de_la_montre(ac.details) AS montre INTO a
      FROM activite_sante ac WHERE ac.id_activite = p_activite;
    IF NOT FOUND THEN
        RETURN NULL;
    END IF;

    SELECT ac.*, activite_de_la_montre(ac.details) AS montre INTO r
      FROM activite_sante ac
     WHERE ac.id_utilisateur = a.id_utilisateur
       AND ac.id_activite <> a.id_activite
       AND ac.doublon_de IS NULL
       AND ac.discipline = a.discipline
       AND ac.periode && a.periode
       AND EXTRACT(EPOCH FROM LEAST(upper(ac.periode), upper(a.periode))
                              - GREATEST(lower(ac.periode), lower(a.periode)))
           > 0.5 * LEAST(EXTRACT(EPOCH FROM upper(ac.periode) - lower(ac.periode)),
                         EXTRACT(EPOCH FROM upper(a.periode) - lower(a.periode)))
     ORDER BY ac.id_activite
     LIMIT 1;

    IF NOT FOUND THEN
        -- Plus de rivale : elle compte de nouveau.
        UPDATE activite_sante SET doublon_de = NULL
         WHERE id_activite = p_activite AND doublon_de IS NOT NULL;
        RETURN p_activite;
    END IF;

    IF a.montre AND NOT r.montre THEN
        -- La nouvelle vient de la montre : elle prend la place, et la séance prévue.
        PERFORM transmettre_activite(r.id_activite, p_activite);
        RETURN p_activite;
    END IF;

    PERFORM transmettre_activite(p_activite, r.id_activite);
    RETURN r.id_activite;
END $$;

COMMENT ON FUNCTION departager_activite(BIGINT) IS
    'SAN-15 : une séance reçue de deux applications n''est comptée qu''une fois,
     celle de la montre d''abord. L''autre pointe vers elle (doublon_de) et
     garde son détail. Rend la séance qui compte.';

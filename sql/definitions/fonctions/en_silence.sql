-- -----------------------------------------------------------------------------
-- Le compte est-il dans ses heures de silence ?                  (NOT-14, NOT-15)
--
-- La plage passe souvent minuit : de 23h30 à 7h30, elle est vraie le soir
-- après le début ou le matin avant la fin.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION en_silence(p_utilisateur INTEGER,
                                      p_instant TIMESTAMPTZ DEFAULT now())
RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
    SELECT CASE
             WHEN u.silence_debut < u.silence_fin
               THEN h >= u.silence_debut AND h < u.silence_fin
             ELSE h >= u.silence_debut OR h < u.silence_fin
           END
      FROM utilisateur u,
           LATERAL (SELECT (p_instant AT TIME ZONE 'Europe/Paris')::TIME AS h) l
     WHERE u.id_utilisateur = p_utilisateur
$$;

COMMENT ON FUNCTION en_silence(INTEGER, TIMESTAMPTZ) IS
    'NOT-14, NOT-15 : vrai pendant les heures de silence que le compte a réglées.';

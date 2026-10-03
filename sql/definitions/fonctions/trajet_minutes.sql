-- -----------------------------------------------------------------------------
-- Trajet à prévoir un jour donné                                          (SPT-4)
--
-- On ne sait pas où l'on sera à l'heure près, seulement si l'on a cours ce
-- jour-là. L'approximation retenue est la plus prudente : on compte le trajet
-- le plus long des deux.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trajet_minutes(
    p_utilisateur INTEGER,
    p_jour        DATE,
    p_lieu        INTEGER
) RETURNS INTEGER LANGUAGE sql STABLE AS $$
    SELECT CASE
        WHEN EXISTS (
            SELECT 1 FROM occupation o
             WHERE o.id_utilisateur = p_utilisateur
               AND o.type = 'cours'
               AND o.periode && tstzrange(debut_jour(p_jour),
                                          debut_jour(p_jour + 1), '[)')
        ) THEN l.minutes_fac
        ELSE l.minutes_domicile
    END
      FROM lieu_sport l WHERE l.id_lieu = p_lieu;
$$;

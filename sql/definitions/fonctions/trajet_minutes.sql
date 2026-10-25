-- -----------------------------------------------------------------------------
-- Trajet à prévoir un jour donné                                  (SPT-4, ADR-9)
--
-- Depuis là où l'on sera ce jour-là, vers l'adresse du lieu de sport, dans le
-- mode de chacun : le trajet calculé par le serveur (ADR-8). Un lieu sans
-- adresse (la course dehors) se pratique sur place.
--
-- Faute de lieu de départ ou de calcul, l'ancienne approximation : on ne sait
-- pas où l'on sera à l'heure près, seulement si l'on a cours ce jour-là, et
-- l'on compte les minutes saisies du lieu.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trajet_minutes(
    p_utilisateur INTEGER,
    p_jour        DATE,
    p_lieu        INTEGER
) RETURNS INTEGER LANGUAGE sql STABLE AS $$
    SELECT COALESCE(
        (SELECT CASE WHEN d.depart = l.id_lieu_connu THEN 0 ELSE t.minutes END
           FROM (SELECT lieu_ou_l_on_sera(p_utilisateur, p_jour) AS depart) d
           LEFT JOIN trajet_calcule t
                  ON t.id_depart = d.depart AND t.id_arrivee = l.id_lieu_connu
                 AND t.mode = mode_du_trajet(p_utilisateur, d.depart, l.id_lieu_connu)
          WHERE l.id_lieu_connu IS NOT NULL AND d.depart IS NOT NULL),
        CASE
            WHEN EXISTS (
                SELECT 1 FROM occupation o
                 WHERE o.id_utilisateur = p_utilisateur
                   AND o.type = 'cours'
                   AND o.periode && tstzrange(debut_jour(p_jour),
                                              debut_jour(p_jour + 1), '[)')
            ) THEN l.minutes_fac
            ELSE l.minutes_domicile
        END)
      FROM lieu_sport l WHERE l.id_lieu = p_lieu;
$$;

COMMENT ON FUNCTION trajet_minutes(INTEGER, DATE, INTEGER) IS
    'SPT-4, ADR-9 : le trajet calculé depuis là où l''on sera, ou les minutes saisies du lieu.';

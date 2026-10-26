-- -----------------------------------------------------------------------------
-- Un lieu de sport, pendant une absence                                (SPT-38)
--
-- Une absence n'interdit pas le sport : elle dit où l'on est. La course dehors,
-- sans adresse, se fait partout. Un lieu qui a une adresse se rejoint s'il est
-- à moins de 15 km du lieu de l'absence ; une absence sans lieu connu (un
-- billet pour Saint-Dié) n'en laisse aucun. On juge à l'heure de la séance :
-- le jour du départ, la salle reste possible le matin, pas après le train.
-- Hors absence, ou pour une séance sans lieu, rien ne change.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION lieu_de_sport_possible(p_utilisateur INTEGER, p_lieu INTEGER,
                                                  p_debut TIMESTAMPTZ)
RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
    SELECT NOT EXISTS (SELECT 1 FROM absence a
                        WHERE a.id_utilisateur = p_utilisateur AND a.periode @> p_debut)
        OR p_lieu IS NULL
        OR EXISTS (SELECT 1 FROM lieu_sport s
                    WHERE s.id_lieu = p_lieu AND s.dehors AND s.id_lieu_connu IS NULL)
        OR EXISTS (
            SELECT 1
              FROM absence a
              JOIN lieu_connu la ON la.id_lieu_connu = a.id_lieu_connu
              JOIN lieu_sport s ON s.id_lieu = p_lieu
              JOIN lieu_connu ls ON ls.id_lieu_connu = s.id_lieu_connu
             WHERE a.id_utilisateur = p_utilisateur
               AND a.periode @> p_debut
               AND distance_m(la.latitude, la.longitude, ls.latitude, ls.longitude) <= 15000);
$$;

COMMENT ON FUNCTION lieu_de_sport_possible(INTEGER, INTEGER, TIMESTAMPTZ) IS
    'SPT-38 : pendant une absence, la course dehors partout, un lieu avec adresse à moins de 15 km du lieu de l''absence.';

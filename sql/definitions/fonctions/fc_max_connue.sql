-- -----------------------------------------------------------------------------
-- La fréquence cardiaque maximale connue d'un compte          (LIB-12, SAN-11)
--
-- La plus haute que la montre ait vue, à défaut l'estimation par l'âge
-- (220 − l'âge). Sert à l'intensité d'une séance libre et aux zones
-- cardiaques d'une course. Vide si on ne sait rien.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fc_max_connue(p_utilisateur INTEGER)
RETURNS INTEGER LANGUAGE sql STABLE AS $$
    SELECT GREATEST(
               (SELECT max(a.fc_max) FROM activite_sante a
                 WHERE a.id_utilisateur = p_utilisateur AND a.doublon_de IS NULL),
               (SELECT 220 - EXTRACT(YEAR FROM age(p.date_naissance))::INTEGER
                  FROM profil p WHERE p.id_utilisateur = p_utilisateur))
$$;

COMMENT ON FUNCTION fc_max_connue(INTEGER) IS
    'LIB-12, SAN-11 : la fréquence cardiaque maximale connue, la plus haute
     vue par la montre, à défaut 220 moins l''âge.';

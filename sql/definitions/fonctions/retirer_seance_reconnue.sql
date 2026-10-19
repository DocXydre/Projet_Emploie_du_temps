-- -----------------------------------------------------------------------------
-- La séance libre née d'un doublon                                      (SAN-15)
--
-- Avant le départage, une même course reçue de la montre et de Strava pouvait
-- créer deux séances : la seconde, une séance libre reconnue après coup
-- (LIB-5). Quand son activité devient un doublon, cette séance ne correspond
-- plus à rien et se retire. Seulement si personne n'y a touché : reconnue
-- toute seule (ni annoncée, ni ouverte dans l'appli), sans série, sans bilan,
-- sans autre activité. Rend vrai si elle a été retirée.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION retirer_seance_reconnue(p_occurrence INTEGER)
RETURNS BOOLEAN LANGUAGE plpgsql AS $$
BEGIN
    DELETE FROM occurrence o
     WHERE o.id_occurrence = p_occurrence
       AND EXISTS (SELECT 1 FROM seance se
                    WHERE se.id_occurrence = o.id_occurrence
                      AND se.libre AND NOT se.annoncee AND se.cle_client IS NULL)
       AND NOT EXISTS (SELECT 1 FROM serie_saisie s WHERE s.id_occurrence = o.id_occurrence)
       AND NOT EXISTS (SELECT 1 FROM bilan_seance b WHERE b.id_occurrence = o.id_occurrence)
       AND NOT EXISTS (SELECT 1 FROM activite_sante a WHERE a.id_occurrence = o.id_occurrence);
    RETURN FOUND;
END $$;

COMMENT ON FUNCTION retirer_seance_reconnue(INTEGER) IS
    'SAN-15 : retire la séance libre reconnue après coup dont l''activité est
     devenue un doublon, si rien n''y a été saisi. Rend vrai si elle l''a été.';

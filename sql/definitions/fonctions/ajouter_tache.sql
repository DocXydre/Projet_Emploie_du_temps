-- -----------------------------------------------------------------------------
-- Ajouter une tâche, une fois ou régulière                             (TAC-20)
--
-- La forme d'avant, celle du bot : un rythme ou une échéance. Elle passe
-- maintenant par `creer_tache()`, qui sait aussi les dates de début, les heures
-- et les liens, et garde les priorités de PLA-14 : une échéance passe avant le
-- ménage courant, un cycle long après lui.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ajouter_tache(p_libelle        TEXT,
                                         p_acteur         INTEGER,
                                         p_tous_les_jours INTEGER DEFAULT NULL,
                                         p_echeance       DATE    DEFAULT NULL,
                                         p_pour           INTEGER DEFAULT NULL,
                                         p_duree_minutes  INTEGER DEFAULT 15)
RETURNS INTEGER LANGUAGE plpgsql AS $$
BEGIN
    IF (p_tous_les_jours IS NULL) = (p_echeance IS NULL) THEN
        RAISE EXCEPTION 'Une tâche est régulière ou ponctuelle : donne un rythme ou une date, pas les deux'
              USING ERRCODE = 'check_violation';
    END IF;

    RETURN creer_tache(p_libelle        => p_libelle,
                       p_acteur         => p_acteur,
                       p_duree_minutes  => COALESCE(p_duree_minutes, 15),
                       p_pour           => p_pour,
                       p_tous_les_jours => p_tous_les_jours,
                       p_au             => p_echeance,
                       p_priorite       => CASE WHEN p_echeance IS NOT NULL THEN 2
                                                WHEN p_tous_les_jours >= 28 THEN 5
                                                ELSE 4 END);
END $$;

COMMENT ON FUNCTION ajouter_tache(TEXT, INTEGER, INTEGER, DATE, INTEGER, INTEGER) IS
    'TAC-20 : crée une tâche régulière (tous les N jours) ou ponctuelle (avant
     une date), pour quelqu''un ou à tour de rôle. Le placement suivant la pose.';

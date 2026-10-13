-- -----------------------------------------------------------------------------
-- Le compte peut-il ajouter, ou modifier et arrêter, une tâche ?    (FOY-6, TAC-21)
--
-- Tout le monde par défaut ; l'administrateur du foyer seul s'il l'a réglé
-- ainsi. L'administrateur du serveur garde la main sur le catalogue (EXO-4).
-- Cocher, déclarer faite et reporter restent ouverts à tous (EXE-14).
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION droit_sur_les_taches(p_utilisateur INTEGER, p_geste TEXT)
RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
    SELECT EXISTS (SELECT 1 FROM utilisateur
                    WHERE id_utilisateur = p_utilisateur AND role = 'admin' AND actif)
        OR EXISTS (SELECT 1
                     FROM utilisateur u
                     JOIN foyer f ON f.id_foyer = u.id_foyer AND f.ferme_le IS NULL
                    WHERE u.id_utilisateur = p_utilisateur AND u.actif
                      AND (f.id_administrateur = u.id_utilisateur
                           OR CASE p_geste WHEN 'ajouter' THEN f.ajout_taches
                                           ELSE f.modif_taches END = 'tous'))
$$;

COMMENT ON FUNCTION droit_sur_les_taches(INTEGER, TEXT) IS
    'FOY-6 : vrai si le compte peut ajouter (« ajouter ») ou modifier et arrêter (« modifier ») une tâche.';

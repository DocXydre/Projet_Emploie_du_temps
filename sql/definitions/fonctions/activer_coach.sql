-- -----------------------------------------------------------------------------
-- Activer ou couper le coach pour un compte                     (COA-1, PRO-7)
--
-- Activer exige un profil : c'est lui qui porte la date de naissance, et le
-- coach ne s'active pas pour une personne mineure. Les réservations « à
-- déterminer » du compte disparaissent : le coach les remplace.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION activer_coach(p_utilisateur INTEGER, p_actif BOOLEAN DEFAULT TRUE)
RETURNS BOOLEAN LANGUAGE plpgsql AS $$
BEGIN
    IF p_actif AND NOT EXISTS (SELECT 1 FROM profil p
                                WHERE p.id_utilisateur = p_utilisateur) THEN
        PERFORM refus_coach('profil_incomplet',
                            'Le profil doit être rempli avant d''activer le coach');
    END IF;

    UPDATE utilisateur SET coach_actif = p_actif WHERE id_utilisateur = p_utilisateur;
    IF NOT FOUND THEN
        PERFORM refus_coach('introuvable', 'Compte inconnu');
    END IF;

    IF p_actif THEN
        DELETE FROM occurrence o
         USING tache t
         WHERE t.id_tache = o.id_tache AND t.categorie = 'sport'
           AND o.id_utilisateur = p_utilisateur
           AND o.origine = 'quota'
           AND o.statut IN ('a_placer', 'planifiee', 'notifiee');
    END IF;
    RETURN p_actif;
END $$;

COMMENT ON FUNCTION activer_coach(INTEGER, BOOLEAN) IS
    'COA-1, PRO-7 : active le coach pour un compte qui a un profil, et retire
     ses réservations à déterminer. Le couper est un retour en arrière d''une ligne.';

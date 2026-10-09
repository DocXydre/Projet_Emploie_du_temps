CREATE OR REPLACE FUNCTION reporter_fenetre(p_utilisateur INTEGER, p_fenetre INTEGER)
RETURNS INTEGER LANGUAGE plpgsql AS $$
BEGIN
    UPDATE fenetre_mesure f SET statut = 'reportee'
     WHERE f.id_fenetre = p_fenetre AND f.id_utilisateur = p_utilisateur
       AND f.statut = 'ouverte';
    IF NOT FOUND THEN
        PERFORM refus_coach('introuvable', 'Fenêtre de mesure introuvable, ou déjà close');
    END IF;
    RETURN p_fenetre;
END $$;

COMMENT ON FUNCTION reporter_fenetre(INTEGER, INTEGER) IS
    'MES-2 : l''utilisateur dit qu''il ne peut pas mesurer maintenant. La
     fenêtre est reportée, et le coach en rouvrira une.';

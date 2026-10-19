-- -----------------------------------------------------------------------------
-- La décision de l'utilisateur sur une demande                 (ACC-4 à ACC-8)
--
-- Seule une demande en attente, non expirée, et la sienne, se décide. Accepter
-- ne fait rien ici : l'API exécute l'action par sa route, puis note
-- « acceptee », ou « echouee » avec le motif de la base si elle refuse.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION decider_demande(
    p_utilisateur INTEGER,
    p_demande     BIGINT,
    p_etat        TEXT,
    p_motif_echec TEXT DEFAULT NULL
) RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE
    v demande%ROWTYPE;
BEGIN
    SELECT * INTO v FROM demande
     WHERE id_demande = p_demande AND id_utilisateur = p_utilisateur
     FOR UPDATE;
    IF NOT FOUND THEN
        PERFORM refus_coach('introuvable', 'Cette demande n''existe pas, ou n''est pas la tienne.');
    END IF;
    IF p_etat NOT IN ('acceptee', 'refusee', 'echouee') THEN
        PERFORM refus_coach('requete_invalide', 'Une demande s''accepte ou se refuse.');
    END IF;
    IF v.etat <> 'en_attente' THEN
        PERFORM refus_coach('deja_decidee', format('Cette demande est déjà %s.',
            CASE v.etat WHEN 'acceptee' THEN 'acceptée' WHEN 'refusee' THEN 'refusée'
                        WHEN 'expiree' THEN 'expirée' ELSE 'échouée' END));
    END IF;
    IF v.expire_le <= now() THEN
        UPDATE demande SET etat = 'expiree', decidee_le = now() WHERE id_demande = p_demande;
        PERFORM refus_coach('demande_expiree', 'Cette demande a expiré : redemande-la.');
    END IF;

    UPDATE demande
       SET etat = p_etat, decidee_le = now(),
           motif_echec = CASE WHEN p_etat = 'echouee' THEN COALESCE(p_motif_echec, '?') END
     WHERE id_demande = p_demande;
END $$;

COMMENT ON FUNCTION decider_demande(INTEGER, BIGINT, TEXT, TEXT) IS
    'ACC-4 à ACC-8 : note la décision sur une demande en attente, la sienne et
     encore valable.';

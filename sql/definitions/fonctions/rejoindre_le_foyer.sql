-- -----------------------------------------------------------------------------
-- Rejoindre un foyer avec une invitation                          (FOY-3, CNX-4)
--
-- Le compte naît ici, dans le foyer de l'invitation : pseudo, clé d'API tirée
-- par l'API, empreinte du mot de passe. Un code expiré, déjà servi ou annulé
-- est refusé avec son motif, sans dire s'il a existé : la route est publique.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION rejoindre_le_foyer(p_empreinte    TEXT,
                                              p_pseudo       TEXT,
                                              p_nom          TEXT,
                                              p_cle_api      TEXT,
                                              p_mot_de_passe TEXT)
RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE
    v_invitation invitation%ROWTYPE;
    v_pseudo     TEXT := lower(btrim(COALESCE(p_pseudo, '')));
    v_nom        TEXT := btrim(COALESCE(NULLIF(btrim(p_nom), ''), initcap(btrim(p_pseudo))));
    v_compte     INTEGER;
BEGIN
    SELECT * INTO v_invitation FROM invitation
     WHERE empreinte_code = p_empreinte
       FOR UPDATE;

    IF NOT FOUND OR v_invitation.servie_le IS NOT NULL OR v_invitation.annulee_le IS NOT NULL
       OR v_invitation.expire_le <= now()
       OR NOT EXISTS (SELECT 1 FROM foyer
                       WHERE id_foyer = v_invitation.id_foyer AND ferme_le IS NULL) THEN
        RAISE EXCEPTION 'Ce code d''invitation n''est plus valable : demande-en un nouveau'
              USING ERRCODE = 'check_violation';
    END IF;

    IF v_pseudo !~ '^[a-z0-9._-]{3,30}$' THEN
        RAISE EXCEPTION 'Le pseudo fait de 3 à 30 caractères : lettres sans accent, chiffres, point, tiret'
              USING ERRCODE = 'check_violation';
    END IF;
    IF EXISTS (SELECT 1 FROM utilisateur WHERE lower(pseudo) = v_pseudo) THEN
        RAISE EXCEPTION 'Ce pseudo est déjà pris' USING ERRCODE = 'check_violation';
    END IF;

    INSERT INTO utilisateur (pseudo, nom, role, cle_api, mot_de_passe, id_foyer)
    VALUES (v_pseudo, left(v_nom, 50), 'standard', p_cle_api, p_mot_de_passe,
            v_invitation.id_foyer)
    RETURNING id_utilisateur INTO v_compte;

    UPDATE invitation SET servie_le = now(), servie_par = v_compte
     WHERE id_invitation = v_invitation.id_invitation;

    -- Le nouveau venu prend sa part du ménage dès maintenant.
    PERFORM appliquer_assignations();
    RETURN v_compte;
END $$;

COMMENT ON FUNCTION rejoindre_le_foyer(TEXT, TEXT, TEXT, TEXT, TEXT) IS
    'FOY-3 : crée le compte de l''invité dans le foyer et consomme l''invitation.';

-- -----------------------------------------------------------------------------
-- Le problème est réglé                                                 (ADM-4)
--
-- Une alerte ouverte se ferme, et le bot le dit. Sans alerte ouverte pour
-- cette clé, rien ne part : un « c'est réglé » sans problème annoncé avant ne
-- voudrait rien dire.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION lever_l_alerte(p_cle TEXT, p_texte TEXT)
RETURNS BOOLEAN LANGUAGE plpgsql AS $$
DECLARE
    v_admin INTEGER;
BEGIN
    UPDATE alerte_admin SET reglee_le = now()
     WHERE cle = p_cle AND reglee_le IS NULL;
    IF NOT FOUND THEN
        RETURN FALSE;
    END IF;

    SELECT id_utilisateur INTO v_admin
      FROM utilisateur WHERE role = 'admin' AND actif
     ORDER BY id_utilisateur LIMIT 1;
    IF v_admin IS NULL THEN
        RETURN FALSE;
    END IF;

    INSERT INTO notification (id_utilisateur, type, contenu, apple_statut)
    VALUES (v_admin, 'administration', p_texte, 'perimee');
    RETURN TRUE;
END $$;

COMMENT ON FUNCTION lever_l_alerte(TEXT, TEXT) IS
    'ADM-4 : ferme une alerte de l''administrateur et dit que c''est réglé.';

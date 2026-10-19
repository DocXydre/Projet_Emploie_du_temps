-- -----------------------------------------------------------------------------
-- Prévenir l'administrateur du serveur                          (ADM-2, ADM-4)
--
-- Un problème, désigné par sa clé. La première fois, le bot le dit. Tant qu'il
-- dure, il ne le redit qu'une fois par heure au plus, et une fois par jour pour
-- une source en panne : elle n'empêche rien de tourner, et la redire toutes les
-- heures noyait le reste. Rend vrai quand un message part.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION alerter_l_administrateur(p_cle TEXT, p_texte TEXT)
RETURNS BOOLEAN LANGUAGE plpgsql AS $$
DECLARE
    v_admin   INTEGER;
    v_annonce TIMESTAMPTZ;
    v_rappel  INTERVAL := CASE WHEN p_cle LIKE 'source:%' THEN INTERVAL '1 day'
                               ELSE INTERVAL '1 hour' END;
BEGIN
    SELECT annoncee_le INTO v_annonce
      FROM alerte_admin WHERE cle = p_cle AND reglee_le IS NULL;

    IF FOUND AND v_annonce > now() - v_rappel THEN
        UPDATE alerte_admin SET texte = p_texte WHERE cle = p_cle;
        RETURN FALSE;
    END IF;

    INSERT INTO alerte_admin (cle, texte)
    VALUES (p_cle, p_texte)
    ON CONFLICT (cle) DO UPDATE
       SET texte       = EXCLUDED.texte,
           annoncee_le = now(),
           ouverte_le  = CASE WHEN alerte_admin.reglee_le IS NULL
                              THEN alerte_admin.ouverte_le ELSE now() END,
           reglee_le   = NULL;

    SELECT id_utilisateur INTO v_admin
      FROM utilisateur WHERE role = 'admin' AND actif
     ORDER BY id_utilisateur LIMIT 1;
    IF v_admin IS NULL THEN
        RETURN FALSE;
    END IF;

    -- Jamais par Apple : l'appli ne montre pas les alertes du serveur.
    INSERT INTO notification (id_utilisateur, type, contenu, apple_statut)
    VALUES (v_admin, 'administration', p_texte, 'perimee');
    RETURN TRUE;
END $$;

COMMENT ON FUNCTION alerter_l_administrateur(TEXT, TEXT) IS
    'ADM-2, ADM-4 : signale un problème à l''administrateur par le bot, au plus
     une fois par heure tant qu''il dure, une fois par jour pour une source.';

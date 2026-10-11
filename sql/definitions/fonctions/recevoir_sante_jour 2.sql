CREATE OR REPLACE FUNCTION recevoir_sante_jour(
    p_utilisateur INTEGER,
    p_jour        DATE,
    p_pas         INTEGER DEFAULT NULL,
    p_fc_repos    INTEGER DEFAULT NULL,
    p_vfc         NUMERIC DEFAULT NULL,
    p_sommeil     INTEGER DEFAULT NULL
) RETURNS BOOLEAN LANGUAGE plpgsql AS $$
DECLARE
    v_creee BOOLEAN;
BEGIN
    IF p_jour > jour_de(now()) THEN
        PERFORM refus_coach('requete_invalide', 'Une donnée de santé ne vient pas du futur');
    END IF;

    -- SAN-5 : un envoi partiel est accepté. Ce qui manque reste vide, et une
    -- valeur déjà reçue n'est pas effacée par un envoi qui ne la porte plus.
    INSERT INTO sante_jour AS sj (id_utilisateur, jour, pas, fc_repos, vfc_ms, sommeil_minutes)
    VALUES (p_utilisateur, p_jour, p_pas, p_fc_repos, p_vfc, p_sommeil)
    ON CONFLICT (id_utilisateur, jour) DO UPDATE
       SET pas             = COALESCE(EXCLUDED.pas, sj.pas),
           fc_repos        = COALESCE(EXCLUDED.fc_repos, sj.fc_repos),
           vfc_ms          = COALESCE(EXCLUDED.vfc_ms, sj.vfc_ms),
           sommeil_minutes = COALESCE(EXCLUDED.sommeil_minutes, sj.sommeil_minutes),
           recue_le        = now()
    RETURNING (xmax = 0) INTO v_creee;
    RETURN v_creee;
END $$;

COMMENT ON FUNCTION recevoir_sante_jour IS
    'SAN-1, SAN-5 : insère ou met à jour les données de santé d''un jour. Rend
     vrai si la ligne vient d''être créée.';

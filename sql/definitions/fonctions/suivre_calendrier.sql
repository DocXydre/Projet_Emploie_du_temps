-- -----------------------------------------------------------------------------
-- Suivre un nouveau calendrier, depuis l'appli               (COL-7, COL-14, COL-16)
--
-- On dit ce que c'est et à qui : des cours, un planning de travail ou un agenda
-- personnel, pour soi ou pour un autre membre du foyer. La source naît active,
-- son lien donné : la collecte suit, demandée par l'API.
--
-- Le code se déduit de la nature et du pseudo : COURS_LORETTE, PERSO_THOMAS_2.
-- Un calendrier personnel garde la forme PERSO_<PSEUDO> que lit
-- `assigner_calendriers_perso` ; les autres reçoivent leur propriétaire ici.
--
-- Le profil de lecture suit la nature : celui de l'ADE pour des cours, qui
-- nettoie les titres et lit les groupes ; le libellé tel quel pour le reste.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION suivre_calendrier(p_auteur  INTEGER,
                                             p_pour    INTEGER,
                                             p_nature  TEXT,
                                             p_libelle TEXT,
                                             p_url     TEXT)
RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE
    v_pour    utilisateur%ROWTYPE;
    v_base    TEXT;
    v_code    TEXT;
    v_rang    INTEGER := 2;
    v_libelle TEXT;
    v_config  JSONB;
    v_id      INTEGER;
BEGIN
    SELECT * INTO v_pour FROM utilisateur WHERE id_utilisateur = p_pour AND actif;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Ce compte n''existe pas' USING ERRCODE = 'no_data_found';
    END IF;
    IF p_pour <> p_auteur
       AND (foyer_de(p_auteur) IS NULL OR foyer_de(p_pour) IS DISTINCT FROM foyer_de(p_auteur)) THEN
        RAISE EXCEPTION 'Tu ne peux ajouter un calendrier que pour un membre de ton foyer'
              USING ERRCODE = 'insufficient_privilege';
    END IF;

    IF p_nature NOT IN ('cours', 'travail', 'perso') THEN
        RAISE EXCEPTION 'Un calendrier est des cours, un planning de travail ou un agenda personnel'
              USING ERRCODE = 'check_violation';
    END IF;
    IF p_url IS NULL OR p_url !~* '^https?://[^/\s]+' THEN
        RAISE EXCEPTION 'Le lien doit commencer par https://' USING ERRCODE = 'check_violation';
    END IF;

    v_libelle := left(COALESCE(NULLIF(btrim(p_libelle), ''),
                               CASE p_nature WHEN 'cours'   THEN 'Cours de '
                                             WHEN 'travail' THEN 'Travail de '
                                             ELSE 'Calendrier de ' END || v_pour.nom), 100);

    -- 26 caractères au plus : la place d'un « _99 » dans les 30 du code.
    v_base := left(CASE p_nature WHEN 'cours' THEN 'COURS' WHEN 'travail' THEN 'TRAVAIL'
                                 ELSE 'PERSO' END
                   || '_' || upper(regexp_replace(v_pour.pseudo, '[^a-zA-Z0-9]', '_', 'g')), 26);
    v_code := v_base;
    WHILE EXISTS (SELECT 1 FROM source WHERE code = v_code) LOOP
        v_code := v_base || '_' || v_rang;
        v_rang := v_rang + 1;
    END LOOP;

    v_config := CASE p_nature
        WHEN 'cours' THEN
            '{"profil": "ade", "type_occupation": "cours", "horizon_jours": 150, "historique_jours": 7}'
        WHEN 'travail' THEN
            '{"profil": "perso", "type_occupation": "travail", "horizon_jours": 60, "historique_jours": 7}'
        ELSE
            '{"profil": "perso", "type_occupation": "autre", "horizon_jours": 150, "historique_jours": 7}'
    END::JSONB;

    INSERT INTO source (code, libelle, mode_collecte, frequence_heures, url, configuration,
                        id_utilisateur, active, etat)
    VALUES (v_code, v_libelle, 'ics', CASE p_nature WHEN 'perso' THEN 6 ELSE 12 END,
            p_url, v_config, p_pour, TRUE, 'ok')
    RETURNING id_source INTO v_id;
    RETURN v_id;
END $$;

COMMENT ON FUNCTION suivre_calendrier(INTEGER, INTEGER, TEXT, TEXT, TEXT) IS
    'COL-7, COL-14 : crée la source d''un calendrier collé dans l''appli, pour soi ou un membre du foyer.';

-- -----------------------------------------------------------------------------
-- Modifier, suspendre ou reprendre une règle                           (CND-14)
--
-- Avec des briques, la règle est redéfinie en entier : ses briques, sa
-- période et sa fréquence sont celles qu'on donne, et la traduction se refait.
-- Avec un état seul, elle se suspend ou reprend. Une règle retirée ou expirée
-- ne se modifie plus : on en pose une nouvelle.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION modifier_regle(p_regle        INTEGER,
                                          p_etat         TEXT      DEFAULT NULL,
                                          p_briques      JSONB     DEFAULT NULL,
                                          p_phrase       TEXT      DEFAULT NULL,
                                          p_validite     DATERANGE DEFAULT NULL,
                                          p_chaque_annee BOOLEAN   DEFAULT FALSE,
                                          p_frequence    JSONB     DEFAULT NULL)
RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE
    r       regle_tache%ROWTYPE;
    v_motif TEXT;
BEGIN
    SELECT * INTO r FROM regle_tache WHERE id_regle_tache = p_regle FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Cette règle n''existe pas' USING ERRCODE = 'no_data_found';
    END IF;
    IF r.etat NOT IN ('active', 'suspendue') THEN
        RAISE EXCEPTION 'Cette règle n''est plus en vigueur : posez-en une nouvelle'
              USING ERRCODE = 'check_violation';
    END IF;
    IF p_etat IS NOT NULL AND p_etat NOT IN ('active', 'suspendue') THEN
        RAISE EXCEPTION 'Une règle est active ou suspendue' USING ERRCODE = 'check_violation';
    END IF;

    IF p_briques IS NOT NULL THEN
        v_motif := motif_regle(r.id_tache, p_briques, p_validite,
                               COALESCE(p_chaque_annee, FALSE), p_frequence);
        IF v_motif IS NOT NULL THEN
            RAISE EXCEPTION '%', v_motif USING ERRCODE = 'check_violation';
        END IF;
        UPDATE regle_tache
           SET phrase = COALESCE(NULLIF(btrim(p_phrase), ''), phrase),
               traduction = traduire_regle(p_briques, p_validite,
                                           COALESCE(p_chaque_annee, FALSE), p_frequence),
               validite = p_validite,
               chaque_annee = COALESCE(p_chaque_annee, FALSE),
               periodicite_min_jours = (p_frequence ->> 'min')::INTEGER,
               periodicite_max_jours = (p_frequence ->> 'max')::INTEGER,
               rythme_nombre = (p_frequence ->> 'fois')::SMALLINT,
               rythme_periode = p_frequence ->> 'par'
         WHERE id_regle_tache = p_regle;
        PERFORM ecrire_briques(p_regle, p_briques);
    END IF;

    IF p_etat IS NOT NULL AND p_etat <> r.etat THEN
        UPDATE regle_tache SET etat = p_etat WHERE id_regle_tache = p_regle;
    END IF;

    -- RAP-3 : une règle changée repart sans dette. Si elle reste impossible,
    -- le placement qui suit la signale de nouveau.
    UPDATE rappel_hal SET declenche_le = NULL
     WHERE id_regle_tache = p_regle AND etat = 'attente' AND evenement = 'impossible';
END $$;

COMMENT ON FUNCTION modifier_regle(INTEGER, TEXT, JSONB, TEXT, DATERANGE, BOOLEAN, JSONB) IS
    'CND-14 : redéfinit une règle (briques, période, fréquence), ou la suspend et la reprend.';

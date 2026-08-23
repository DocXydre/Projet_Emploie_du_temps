-- rejouable : ce fichier ne contient que des CREATE OR REPLACE ou des IF NOT
--             EXISTS. Le rejouer après modification est sans effet de bord.
-- =============================================================================
-- 010 : départ et retour déclarés à la main                   (ABS-6, ABS-7)
--
-- Tout le reste déduit les absences : billets, horaires, fenêtres. Ces deux
-- fonctions rendent la main, en fermant ou en ouvrant une absence à l'instant
-- où on le dit.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- Déclarer son retour                                                     (ABS-6)
--
-- Un trajet prévu n'engage à rien. Fermer l'absence à l'instant présent rend
-- au ménage les jours qui restaient gelés — y compris celui-ci, puisqu'une
-- journée ne compte absente que si elle est entièrement couverte.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION terminer_absence(
    p_utilisateur INTEGER,
    p_instant     TIMESTAMPTZ DEFAULT now()
) RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE
    v_absence absence;
BEGIN
    SELECT * INTO v_absence
      FROM absence
     WHERE id_utilisateur = p_utilisateur
       AND periode @> p_instant
     ORDER BY lower(periode)
     LIMIT 1;

    IF NOT FOUND THEN
        -- Rentrer d'un voyage qu'on n'a pas commencé n'est pas une erreur à
        -- signaler par une exception : l'appelant a besoin de le dire
        -- gentiment, pas d'attraper une panne.
        RETURN NULL;
    END IF;

    IF lower(v_absence.periode) >= p_instant THEN
        DELETE FROM absence WHERE id_absence = v_absence.id_absence;
        RETURN v_absence.id_absence;
    END IF;

    UPDATE absence
       SET periode = tstzrange(lower(periode), p_instant, '[)'),
           commentaire = COALESCE(commentaire || ' — ', '') || 'retour déclaré'
     WHERE id_absence = v_absence.id_absence;

    RETURN v_absence.id_absence;
END $$;

COMMENT ON FUNCTION terminer_absence IS
    'Ferme l''absence en cours à l''instant donné, et rend les jours restants '
    'au ménage (ABS-6).';


-- -----------------------------------------------------------------------------
-- Déclarer son départ, sans savoir quand on rentre                        (ABS-7)
--
-- Même raisonnement que pour un aller sans retour : l'absence court jusqu'à ce
-- qui nous rappelle. Choisir une durée au hasard serait pire, puisqu'il
-- faudrait la corriger ensuite.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION partir_maintenant(
    p_utilisateur INTEGER,
    p_lieu        VARCHAR DEFAULT NULL,
    p_instant     TIMESTAMPTZ DEFAULT now()
) RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE
    v_fin     TIMESTAMPTZ;
    v_absence INTEGER;
BEGIN
    IF EXISTS (SELECT 1 FROM absence
                WHERE id_utilisateur = p_utilisateur AND periode @> p_instant) THEN
        RAISE EXCEPTION 'Une absence est déjà en cours'
            USING ERRCODE = 'check_violation';
    END IF;

    SELECT f.fin INTO v_fin
      FROM fenetres_de_depart(p_utilisateur,
                              p_instant - INTERVAL '1 minute',
                              p_instant + INTERVAL '30 days',
                              1) f
     ORDER BY f.debut
     LIMIT 1;

    -- Rien de connu dans le mois : deux jours, le temps qu'un retour se
    -- déclare. Mieux vaut trop court que trop long — une absence qui traîne
    -- gèle le ménage sans que personne ne s'en aperçoive.
    v_fin := COALESCE(v_fin, p_instant + INTERVAL '2 days');

    INSERT INTO absence (id_utilisateur, periode, lieu, origine, commentaire)
    VALUES (p_utilisateur, tstzrange(p_instant, v_fin, '[)'),
            p_lieu, 'manuelle', 'départ déclaré, retour à confirmer')
    RETURNING id_absence INTO v_absence;

    RETURN v_absence;
END $$;

COMMENT ON FUNCTION partir_maintenant IS
    'Ouvre une absence à l''instant présent, jusqu''à la prochaine obligation '
    'connue (ABS-7).';

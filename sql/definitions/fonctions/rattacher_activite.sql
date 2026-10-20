-- -----------------------------------------------------------------------------
-- Une séance de la montre trouve sa séance prévue              (SAN-4, LIB-5)
--
-- Même compte, même jour, même discipline, séance sans activité déjà
-- rattachée. Faute de séance prévue, elle devient une séance libre, reconnue
-- d'elle-même. Une activité d'une discipline que le module ne couvre pas
-- (natation, vélo dehors) reste sans séance.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION rattacher_activite(p_activite BIGINT)
RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE
    a            RECORD;
    v_occurrence INTEGER;
BEGIN
    SELECT ac.*, jour_de(lower(ac.periode)) AS jour INTO a
      FROM activite_sante ac WHERE ac.id_activite = p_activite;
    IF NOT FOUND THEN
        RETURN NULL;
    END IF;
    -- SAN-15 : un doublon ne se rattache à rien, la séance qui compte le fait.
    IF a.doublon_de IS NOT NULL THEN
        RETURN NULL;
    END IF;
    IF a.id_occurrence IS NOT NULL OR a.discipline = 'autre' THEN
        RETURN a.id_occurrence;
    END IF;
    -- SAN-8 : une séance de plus de 28 jours arrive avec l'historique. Elle est
    -- gardée telle quelle pour le coach, mais ne se rattache à rien et ne crée
    -- aucune séance libre : le planning passé ne se remplit pas après coup.
    IF a.jour < jour_de(now()) - 28 THEN
        RETURN NULL;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM utilisateur u
                    WHERE u.id_utilisateur = a.id_utilisateur AND u.coach_actif) THEN
        RETURN NULL;
    END IF;

    v_occurrence := seance_pour_activite(a.id_utilisateur, a.discipline, lower(a.periode));

    -- La séance libre porte le nom français de l'activité (« Course sur
    -- tapis »), pas le type brut de la montre (« running »).
    IF v_occurrence IS NULL THEN
        v_occurrence := creer_seance_libre(
            a.id_utilisateur, a.discipline, lower(a.periode),
            CEIL(a.duree_secondes / 60.0)::INTEGER, NULL, FALSE, NULL,
            nom_seance_montre(a.type, a.details -> 'interieur' = 'true'));
    END IF;

    UPDATE activite_sante ac SET id_occurrence = v_occurrence
     WHERE ac.id_activite = p_activite;
    PERFORM deduire_intensite(v_occurrence);
    RETURN v_occurrence;
END $$;

COMMENT ON FUNCTION rattacher_activite(BIGINT) IS
    'SAN-4, LIB-5 : rattache une séance de la montre à la séance prévue du même
     jour et de la même discipline. À défaut, crée une séance libre, nommée
     en français d''après le type de la montre. Rien pour une séance de plus
     de 28 jours (SAN-8).';

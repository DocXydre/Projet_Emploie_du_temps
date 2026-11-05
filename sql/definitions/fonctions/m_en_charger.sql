-- -----------------------------------------------------------------------------
-- « Je m'en charge » : prendre une tâche sans la valider               (EXE-18)
--
-- Sur une tâche en retard ou prévue pour un autre membre : elle change
-- d'assigné et s'épingle à celui qui la prend (PLA-5 : le placement ne la
-- déplace plus). Elle n'est pas faite pour autant : seule la validation la
-- crédite (EXE-14). L'ancien assigné est prévenu comme en EXE-16 (cf.
-- valider_occurrence), et la semaine se rouvre à la répartition (PLA-13).
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION m_en_charger(
    p_occurrence INTEGER,
    p_acteur     INTEGER
) RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE
    o        RECORD;
    v_ancien INTEGER;
    v_retard BOOLEAN;
    v_motif  TEXT;
BEGIN
    SELECT * INTO o FROM occurrence WHERE id_occurrence = p_occurrence FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Occurrence % introuvable', p_occurrence
              USING ERRCODE = 'no_data_found';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM utilisateur
                    WHERE id_utilisateur = p_acteur AND actif) THEN
        RAISE EXCEPTION 'Compte % inconnu ou désactivé', p_acteur
              USING ERRCODE = 'insufficient_privilege';
    END IF;

    -- Une séance de sport est personnelle (SPT-25) : la tâche du sport est la
    -- seule sans type.
    IF EXISTS (SELECT 1 FROM tache WHERE id_tache = o.id_tache AND id_type_tache IS NULL) THEN
        RAISE EXCEPTION 'Une séance de sport ne se prend pas pour soi'
              USING ERRCODE = 'check_violation';
    END IF;

    IF o.statut NOT IN ('a_placer', 'planifiee', 'notifiee') THEN
        v_motif := CASE o.statut WHEN 'faite' THEN 'déjà faite'
                                 WHEN 'abandonnee' THEN 'abandonnée'
                                 ELSE 'reportée' END;
        RAISE EXCEPTION 'Cette tâche est %', v_motif
              USING ERRCODE = 'check_violation';
    END IF;

    -- RGL-7 : une tâche à plusieurs est déjà à tous.
    IF EXISTS (SELECT 1 FROM occurrence_participant WHERE id_occurrence = p_occurrence) THEN
        RAISE EXCEPTION 'Cette tâche se fait à plusieurs : elle est déjà à tous'
              USING ERRCODE = 'check_violation';
    END IF;

    -- EXE-4, EXE-6 : en retard comme v_occurrence.en_retard (échéance dépassée
    -- ou au moins un report d'office).
    v_retard := upper(o.fenetre) < now() OR o.nb_relances > 0;
    IF o.id_utilisateur = p_acteur AND NOT v_retard THEN
        RAISE EXCEPTION 'Cette tâche est déjà à toi'
              USING ERRCODE = 'check_violation';
    END IF;

    v_ancien := o.id_utilisateur;

    -- 'admin' = épinglée à la main, valeur déjà permise par occurrence_epinglee_par.
    UPDATE occurrence
       SET id_utilisateur = p_acteur,
           epinglee       = TRUE,
           epinglee_par   = 'admin'
     WHERE id_occurrence = p_occurrence;

    -- EXE-18 : l'ancien assigné l'apprend, et le rappel qui l'attendait part.
    IF v_ancien IS NOT NULL AND v_ancien <> p_acteur THEN
        DELETE FROM notification
         WHERE id_occurrence = p_occurrence
           AND id_utilisateur = v_ancien
           AND statut = 'a_envoyer';

        INSERT INTO notification (id_utilisateur, id_occurrence, type, contenu)
        SELECT v_ancien, p_occurrence, 'alerte',
               format('🙋 %s s''en charge de « %s ». Elle quitte ta liste.',
                      (SELECT nom FROM utilisateur WHERE id_utilisateur = p_acteur),
                      (SELECT libelle FROM tache WHERE id_tache = o.id_tache));

        -- PLA-13 : la balance a bougé ; ce qui est épinglé ne bouge pas.
        PERFORM reequilibrer();
    END IF;

    RETURN p_occurrence;
END $$;

COMMENT ON FUNCTION m_en_charger(INTEGER, INTEGER) IS
    'EXE-18 : prend pour soi une tâche en retard ou prévue pour un autre, sans la valider : elle change d''assigné, s''épingle à celui qui la prend, et l''ancien assigné est prévenu. Refuse le fait, l''abandonné, le reporté, le sport, le à plusieurs, et ce qui est déjà à soi sans retard.';

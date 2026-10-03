-- -----------------------------------------------------------------------------
-- Valider, prévenir, rééquilibrer                              (EXE-14, EXE-16)
--
-- Corps repris de la migration 036, avec la suite qui manquait.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION valider_occurrence(
    p_occurrence  INTEGER,
    p_acteur      INTEGER,
    p_date_reelle TIMESTAMPTZ DEFAULT NULL
) RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE
    o        RECORD;
    v_ancien INTEGER;
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

    v_ancien := o.id_utilisateur;

    UPDATE occurrence
       SET statut         = 'faite',
           id_utilisateur = p_acteur,
           date_faite     = COALESCE(p_date_reelle, now())
     WHERE id_occurrence = p_occurrence;

    -- Un rappel qui n'est pas encore parti n'a plus d'objet : la tâche est
    -- faite. Le laisser partirait demander à quelqu'un de faire ce qui l'est.
    DELETE FROM notification
     WHERE id_occurrence = p_occurrence AND statut = 'a_envoyer';

    -- EXE-16 : la tâche quitte la liste de l'autre, il faut qu'il l'apprenne
    -- autrement qu'en constatant un trou.
    IF v_ancien IS NOT NULL AND v_ancien <> p_acteur THEN
        INSERT INTO notification (id_utilisateur, id_occurrence, type, contenu)
        SELECT v_ancien, p_occurrence, 'alerte',
               format('👍 %s a fait « %s » à ta place. Elle quitte ta liste, '
                      || 'et je rééquilibre la suite de la semaine.',
                      (SELECT nom FROM utilisateur WHERE id_utilisateur = p_acteur),
                      (SELECT libelle FROM tache WHERE id_tache = o.id_tache));

        -- PLA-13 : la balance a bougé, la répartition doit suivre.
        PERFORM reequilibrer();
    END IF;

    RETURN p_occurrence;
END $$;

COMMENT ON FUNCTION valider_occurrence IS
    'Marque une occurrence faite et la crédite à celui qui la valide, même
     prévue pour l''autre (EXE-14). Le prévient (EXE-16) et rouvre la semaine
     à la répartition (PLA-13).';

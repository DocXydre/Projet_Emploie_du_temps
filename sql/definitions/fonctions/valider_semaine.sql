-- -----------------------------------------------------------------------------
-- L'utilisateur valide sa semaine en une fois           (opération C5)
--                                                          (PLN-6, PLN-24)
--
-- Toutes les séances proposées de la semaine deviennent validées, donc
-- épinglées. Tant qu'il reste une esquisse, la validation est refusée : on ne
-- s'engage pas sur une séance dont on ne connaît pas le contenu.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION valider_semaine(p_utilisateur INTEGER, p_lundi DATE)
RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE
    v_esquisses INTEGER;
    v_nombre    INTEGER;
BEGIN
    IF EXTRACT(ISODOW FROM p_lundi) <> 1 THEN
        PERFORM refus_coach('requete_invalide', 'Une semaine se désigne par son lundi');
    END IF;

    SELECT count(*),
           count(*) FILTER (WHERE NOT EXISTS (SELECT 1 FROM seance_exercice x
                                               WHERE x.id_occurrence = se.id_occurrence))
      INTO v_nombre, v_esquisses
      FROM seance se JOIN occurrence o ON o.id_occurrence = se.id_occurrence
     WHERE o.id_utilisateur = p_utilisateur
       AND se.auteur = 'coach' AND se.etat = 'proposee'
       AND o.statut IN ('planifiee', 'notifiee')
       AND lundi_de(jour_de(o.debut_seance)) = p_lundi;

    IF v_nombre = 0 THEN
        PERFORM refus_coach('introuvable', 'Aucune séance à valider cette semaine');
    END IF;
    IF v_esquisses > 0 THEN
        PERFORM refus_coach('seance_a_detailler',
            format('%s séance(s) de la semaine ne sont encore que des esquisses : '
                   || 'le coach doit les détailler avant la validation', v_esquisses));
    END IF;

    UPDATE seance se SET etat = 'validee'
      FROM occurrence o
     WHERE o.id_occurrence = se.id_occurrence
       AND o.id_utilisateur = p_utilisateur
       AND se.auteur = 'coach' AND se.etat = 'proposee'
       AND o.statut IN ('planifiee', 'notifiee')
       AND lundi_de(jour_de(o.debut_seance)) = p_lundi;

    UPDATE plan_semaine ps SET validee_le = now()
      FROM plan p
     WHERE p.id_plan = ps.id_plan AND p.id_utilisateur = p_utilisateur
       AND p.statut = 'en_cours' AND ps.lundi = p_lundi;

    RETURN v_nombre;
END $$;

COMMENT ON FUNCTION valider_semaine(INTEGER, DATE) IS
    'PLN-6, PLN-24 : valide et épingle toutes les séances proposées de la
     semaine. Refuse tant qu''il reste une esquisse.';

-- -----------------------------------------------------------------------------
-- Le coach change une séance encore proposée           (PLN-7, PLN-22, LIE-2)
--
-- Contenu, lieu, jour ou plage d'heures. C'est aussi par là qu'une esquisse
-- reçoit ses exercices. Une séance validée est refusée : le coach n'y touche
-- plus que par un ajustement (PLN-18).
--
-- p_champs ne porte que ce qui change : type_seance, intensite,
-- duree_minutes, jour, heure_min, heure_max, id_lieu, cle, est_test, groupes,
-- consigne, exercices.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION modifier_seance_proposee(
    p_utilisateur INTEGER,
    p_occurrence  INTEGER,
    p_champs      JSONB
) RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE
    s           RECORD;
    r           RECORD;
    v_jour      DATE;
    v_duree     INTEGER;
    v_lieu      INTEGER;
    v_intensite VARCHAR;
    v_groupes   TEXT[];
    v_ids       INTEGER[];
    v_exercices JSONB := p_champs -> 'exercices';
    v_debut     TIMESTAMPTZ;
    v_bloc      TSTZRANGE;
    v_replacer  BOOLEAN;
BEGIN
    PERFORM exiger_coach(p_utilisateur);

    SELECT se.*, o.statut, o.id_lieu, o.debut_seance, o.creneau,
           jour_de(o.debut_seance) AS jour
      INTO s
      FROM seance se JOIN occurrence o ON o.id_occurrence = se.id_occurrence
     WHERE se.id_occurrence = p_occurrence
       AND o.id_utilisateur = p_utilisateur
       AND se.auteur = 'coach';
    IF NOT FOUND THEN
        PERFORM refus_coach('introuvable', 'Séance du coach introuvable');
    END IF;
    IF s.statut NOT IN ('planifiee', 'notifiee') THEN
        PERFORM refus_coach('introuvable', 'Cette séance est déjà close');
    END IF;
    IF s.etat = 'validee' THEN
        PERFORM refus_coach('seance_validee',
            'Cette séance est validée : dépose un ajustement, l''utilisateur tranche');
    END IF;

    v_jour      := COALESCE((p_champs ->> 'jour')::DATE, s.jour);
    v_duree     := COALESCE((p_champs ->> 'duree_minutes')::INTEGER, s.duree_minutes);
    v_intensite := COALESCE(p_champs ->> 'intensite', s.intensite);

    IF en_pause(p_utilisateur, v_jour) THEN
        PERFORM refus_coach('coach_en_pause', 'Le coach est en pause ce jour-là');
    END IF;
    IF v_duree NOT BETWEEN 15 AND 240 THEN
        PERFORM refus_coach('requete_invalide',
                            'La durée d''une séance va de 15 à 240 minutes');
    END IF;

    v_lieu := CASE WHEN p_champs ? 'id_lieu'
                   THEN lieu_de_discipline(p_utilisateur, s.discipline,
                                           (p_champs ->> 'id_lieu')::INTEGER)
                   ELSE s.id_lieu END;

    -- Les exercices et les groupes, tels qu'ils seront après la modification.
    IF v_exercices IS NOT NULL THEN
        v_ids := verifier_exercices(p_utilisateur, s.discipline, v_exercices, v_jour);
    ELSE
        SELECT COALESCE(array_agg(se.id_exercice), '{}') INTO v_ids
          FROM seance_exercice se WHERE se.id_occurrence = p_occurrence;
    END IF;
    IF s.discipline <> 'musculation' THEN
        v_groupes := ARRAY['cardio'];
    ELSIF cardinality(v_ids) > 0 THEN
        SELECT array_agg(DISTINCT e.groupe_principal) INTO v_groupes
          FROM exercice e WHERE e.id_exercice = ANY (v_ids);
    ELSIF p_champs ? 'groupes' THEN
        SELECT array_agg(g) INTO v_groupes
          FROM jsonb_array_elements_text(p_champs -> 'groupes') g;
    ELSE
        v_groupes := s.groupes;
    END IF;
    IF COALESCE(cardinality(v_groupes), 0) = 0 THEN
        PERFORM refus_coach('requete_invalide',
            'Une esquisse de musculation doit dire quels groupes elle sollicite');
    END IF;

    SELECT os.code, os.motif INTO r
      FROM obstacle_sportif(p_utilisateur, NULL, v_intensite, v_groupes, v_ids,
                            p_occurrence, TRUE) os
     WHERE os.bloquant LIMIT 1;
    IF FOUND THEN
        PERFORM refus_coach(r.code, r.motif);
    END IF;

    v_replacer := p_champs ?| ARRAY['jour', 'heure_min', 'heure_max', 'id_lieu', 'duree_minutes'];
    IF v_replacer THEN
        v_debut := chercher_debut_seance(
            p_utilisateur, v_lieu, v_jour,
            COALESCE((p_champs ->> 'heure_min')::TIME,
                     (s.debut_seance AT TIME ZONE 'Europe/Paris')::TIME),
            COALESCE((p_champs ->> 'heure_max')::TIME,
                     LEAST((s.debut_seance AT TIME ZONE 'Europe/Paris')::TIME
                           + make_interval(mins => v_duree), TIME '23:59')),
            v_duree, s.discipline, v_intensite, v_groupes, p_occurrence);
        v_bloc := bloc_seance_duree(p_utilisateur, v_lieu, v_debut, v_duree);

        UPDATE occurrence o
           SET creneau = NULL, statut = 'a_placer',
               motif = 'Déplacée par une séance de sport'
         WHERE o.id_utilisateur = p_utilisateur
           AND o.statut = 'planifiee' AND NOT o.epinglee AND NOT o.rappel_journee
           AND o.origine NOT IN ('quota', 'coach')
           AND o.creneau && v_bloc;

        UPDATE occurrence o
           SET creneau = v_bloc,
               fenetre = tstzrange(LEAST(debut_jour(v_jour), lower(v_bloc)),
                                   GREATEST(debut_jour(v_jour + 1), upper(v_bloc)), '[)'),
               id_lieu = v_lieu,
               debut_seance = v_debut,
               motif = 'Modifiée par le coach'
         WHERE o.id_occurrence = p_occurrence;
    ELSE
        -- Même place : seule la règle des séances dures peut encore refuser.
        SELECT os.code, os.motif INTO r
          FROM obstacle_sportif(p_utilisateur, s.debut_seance, v_intensite, v_groupes,
                                NULL, p_occurrence, TRUE) os
         WHERE os.bloquant LIMIT 1;
        IF FOUND THEN
            PERFORM refus_coach(r.code, r.motif);
        END IF;
    END IF;

    UPDATE seance se
       SET type_seance   = left(COALESCE(p_champs ->> 'type_seance', se.type_seance), 40),
           intensite     = v_intensite,
           duree_minutes = v_duree,
           cle           = COALESCE((p_champs ->> 'cle')::BOOLEAN, se.cle),
           est_test      = COALESCE((p_champs ->> 'est_test')::BOOLEAN, se.est_test),
           groupes       = v_groupes,
           consigne      = CASE WHEN p_champs ? 'consigne' THEN p_champs ->> 'consigne'
                                ELSE se.consigne END
     WHERE se.id_occurrence = p_occurrence;

    IF v_exercices IS NOT NULL THEN
        PERFORM ecrire_exercices(p_occurrence, v_exercices);
    END IF;

    PERFORM tracer_coach(p_utilisateur, 'seance_proposee', p_occurrence);
    RETURN p_occurrence;
END $$;

COMMENT ON FUNCTION modifier_seance_proposee(INTEGER, INTEGER, JSONB) IS
    'PLN-7, PLN-22 : change une séance encore proposée, ou détaille une
     esquisse. Mêmes contrôles qu''une proposition. Refuse une séance validée.';

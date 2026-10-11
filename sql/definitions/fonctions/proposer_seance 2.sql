-- -----------------------------------------------------------------------------
-- Le coach propose une séance                                (opération C4)
--                              (PLN-5, PLN-14, PLN-22, LIE-2, EXO-5, SEC, PAU-2)
--
-- La seule porte d'entrée d'une séance du coach au planning. Au premier
-- contrôle qui échoue, rien n'est créé et le motif est rendu : le coach
-- corrige et propose à nouveau.
--
-- Sans exercices, c'est une esquisse : elle occupe son créneau et compte pour
-- la règle des séances dures, et ses groupes sont alors donnés par l'appelant.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION proposer_seance(
    p_utilisateur INTEGER,
    p_discipline  VARCHAR,
    p_type        VARCHAR,
    p_intensite   VARCHAR,
    p_duree       INTEGER,
    p_jour        DATE,
    p_heure_min   TIME,
    p_heure_max   TIME,
    p_lieu        INTEGER DEFAULT NULL,
    p_cle         BOOLEAN DEFAULT FALSE,
    p_test        BOOLEAN DEFAULT FALSE,
    p_groupes     TEXT[]  DEFAULT NULL,
    p_consigne    TEXT    DEFAULT NULL,
    p_exercices   JSONB   DEFAULT NULL,
    p_remplace    INTEGER DEFAULT NULL
) RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE
    v_tache      INTEGER;
    v_lieu       INTEGER;
    v_plan       INTEGER;
    v_ids        INTEGER[];
    v_groupes    TEXT[];
    v_max        INTEGER;
    v_nombre     INTEGER;
    v_debut      TIMESTAMPTZ;
    v_bloc       TSTZRANGE;
    v_occurrence INTEGER;
    s            RECORD;
BEGIN
    PERFORM exiger_coach(p_utilisateur);

    IF en_pause(p_utilisateur, p_jour) THEN
        PERFORM refus_coach('coach_en_pause',
            'Le coach est en pause ce jour-là : aucune séance ne se propose');
    END IF;

    SELECT t.id_tache INTO v_tache FROM tache t WHERE t.code = 'SPORT' AND t.active;
    IF v_tache IS NULL THEN
        PERFORM refus_coach('introuvable', 'Le sport est désactivé');
    END IF;

    IF p_duree IS NULL OR p_duree NOT BETWEEN 15 AND 240 THEN
        PERFORM refus_coach('requete_invalide',
                            'La durée d''une séance va de 15 à 240 minutes');
    END IF;

    v_lieu := lieu_de_discipline(p_utilisateur, p_discipline, p_lieu);

    -- Une séance du coach appartient au plan en cours. Seule la séance qui en
    -- remplace une autre, pas faite, peut se proposer sans lui (PLN-10).
    SELECT p.id_plan INTO v_plan
      FROM plan p
     WHERE p.id_utilisateur = p_utilisateur AND p.statut = 'en_cours'
       AND p.periode @> p_jour;
    IF v_plan IS NULL AND p_remplace IS NULL THEN
        PERFORM refus_coach('hors_plan',
            'Ce jour n''est couvert par aucun plan en cours : écris d''abord la trame');
    END IF;

    -- Les groupes sollicités : ceux des exercices quand il y en a, sinon ceux
    -- que le coach donne pour l'esquisse. La course et les machines cardio
    -- forment un groupe à elles (SEC-3).
    v_ids := verifier_exercices(p_utilisateur, p_discipline, p_exercices, p_jour);
    IF p_discipline <> 'musculation' THEN
        v_groupes := ARRAY['cardio'];
    ELSIF cardinality(v_ids) > 0 THEN
        SELECT array_agg(DISTINCT e.groupe_principal) INTO v_groupes
          FROM exercice e WHERE e.id_exercice = ANY (v_ids);
    ELSE
        v_groupes := p_groupes;
    END IF;
    IF COALESCE(cardinality(v_groupes), 0) = 0 THEN
        PERFORM refus_coach('requete_invalide',
            'Une esquisse de musculation doit dire quels groupes elle sollicite');
    END IF;

    -- SEC-1 : aucun exercice interdit, quelle que soit l'heure.
    SELECT os.code, os.motif INTO s
      FROM obstacle_sportif(p_utilisateur, NULL, p_intensite, v_groupes, v_ids,
                            NULL, TRUE) os
     WHERE os.bloquant
     LIMIT 1;
    IF FOUND THEN
        PERFORM refus_coach(s.code, s.motif);
    END IF;

    -- PLN-14 : le maximum de la semaine, séances posées à la main comprises.
    SELECT u.seances_max_semaine INTO v_max
      FROM utilisateur u WHERE u.id_utilisateur = p_utilisateur;
    IF v_max IS NOT NULL THEN
        SELECT count(*) INTO v_nombre
          FROM occurrence o JOIN tache t ON t.id_tache = o.id_tache
         WHERE o.id_utilisateur = p_utilisateur
           AND t.categorie = 'sport' AND o.origine <> 'quota'
           AND o.statut IN ('planifiee', 'notifiee', 'faite')
           AND lundi_de(jour_de(COALESCE(o.debut_seance, lower(o.creneau),
                                         lower(o.fenetre)))) = lundi_de(p_jour);
        IF v_nombre >= v_max THEN
            PERFORM refus_coach('maximum_semaine',
                format('La semaine compte déjà %s séances, le maximum fixé est %s',
                       v_nombre, v_max));
        END IF;
    END IF;

    v_debut := chercher_debut_seance(p_utilisateur, v_lieu, p_jour, p_heure_min,
                                     p_heure_max, p_duree, p_discipline, p_intensite,
                                     v_groupes);
    v_bloc := bloc_seance_duree(p_utilisateur, v_lieu, v_debut, p_duree);

    -- Une séance passe avant le ménage, qui se replace autour.
    UPDATE occurrence o
       SET creneau = NULL, statut = 'a_placer',
           motif = 'Déplacée par une séance de sport'
     WHERE o.id_utilisateur = p_utilisateur
       AND o.statut = 'planifiee'
       AND NOT o.epinglee
       AND NOT o.rappel_journee
       AND o.origine NOT IN ('quota', 'coach')
       AND o.creneau && v_bloc;
    DELETE FROM occurrence o
     WHERE o.id_utilisateur = p_utilisateur
       AND o.id_tache = v_tache AND o.origine = 'quota'
       AND o.statut IN ('a_placer', 'planifiee', 'notifiee')
       AND (o.creneau && v_bloc OR jour_de(o.debut_seance) = p_jour);

    INSERT INTO occurrence (id_tache, id_utilisateur, fenetre, creneau, statut,
                            origine, epinglee, id_lieu, debut_seance, motif, titre)
    VALUES (v_tache, p_utilisateur,
            tstzrange(LEAST(debut_jour(p_jour), lower(v_bloc)),
                      GREATEST(debut_jour(p_jour + 1), upper(v_bloc)), '[)'),
            v_bloc, 'planifiee', 'coach', FALSE, v_lieu, v_debut,
            'Proposée par le coach', titre_seance(p_discipline, 'proposee', FALSE))
    RETURNING id_occurrence INTO v_occurrence;

    INSERT INTO seance (id_occurrence, id_plan, auteur, etat, discipline, type_seance,
                        intensite, cle, est_test, duree_minutes, groupes, consigne,
                        id_occurrence_remplacee)
    VALUES (v_occurrence, v_plan, 'coach', 'proposee', p_discipline, left(p_type, 40),
            p_intensite, COALESCE(p_cle, FALSE), COALESCE(p_test, FALSE), p_duree,
            v_groupes, p_consigne, p_remplace);

    PERFORM ecrire_exercices(v_occurrence, p_exercices);
    PERFORM tracer_coach(p_utilisateur, 'seance_proposee', v_occurrence);
    RETURN v_occurrence;
END $$;

COMMENT ON FUNCTION proposer_seance IS
    'Opération C4 : fait entrer une séance du coach au planning si elle tient.
     Lieu de la discipline, exercices du catalogue, placement strict, sécurité,
     maximum de la semaine. Sans exercices, une esquisse (PLN-5, PLN-22).';

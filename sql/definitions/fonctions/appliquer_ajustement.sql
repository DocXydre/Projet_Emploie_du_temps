-- -----------------------------------------------------------------------------
-- Applique la version proposée par un ajustement                      (PLN-19)
--
-- Appelée quand l'utilisateur accepte, ou quand un allègement ou un retrait
-- est resté sans réponse au début de la séance. Les contrôles sont rejoués :
-- l'emploi du temps a pu changer entre le dépôt et l'application.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION appliquer_ajustement(p_ajustement INTEGER)
RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE
    a           RECORD;
    r           RECORD;
    v_ids       INTEGER[];
    v_groupes   TEXT[];
    v_intensite VARCHAR;
    v_duree     INTEGER;
    v_lieu      INTEGER;
    v_jour      DATE;
    v_debut     TIMESTAMPTZ;
    v_bloc      TSTZRANGE;
BEGIN
    SELECT aj.*, se.discipline, se.intensite, se.duree_minutes, se.groupes,
           o.id_utilisateur, o.id_lieu, o.debut_seance, o.statut AS statut_occurrence,
           jour_de(o.debut_seance) AS jour
      INTO a
      FROM ajustement aj
      JOIN seance se    ON se.id_occurrence = aj.id_occurrence
      JOIN occurrence o ON o.id_occurrence = aj.id_occurrence
     WHERE aj.id_ajustement = p_ajustement;
    IF NOT FOUND OR a.statut_occurrence NOT IN ('planifiee', 'notifiee') THEN
        PERFORM refus_coach('introuvable', 'Ajustement introuvable, ou séance déjà close');
    END IF;

    IF a.nature = 'retirer' THEN
        UPDATE occurrence o
           SET statut = 'abandonnee', motif = 'Retirée sur proposition du coach'
         WHERE o.id_occurrence = a.id_occurrence;
        RETURN;
    END IF;

    v_intensite := COALESCE(a.contenu ->> 'intensite', a.intensite);
    v_duree     := COALESCE((a.contenu ->> 'duree_minutes')::INTEGER, a.duree_minutes);

    IF a.nature = 'deplacer' THEN
        v_jour := COALESCE((a.contenu ->> 'jour')::DATE, a.jour);
        v_lieu := CASE WHEN a.contenu ? 'id_lieu'
                       THEN lieu_de_discipline(a.id_utilisateur, a.discipline,
                                               (a.contenu ->> 'id_lieu')::INTEGER)
                       ELSE a.id_lieu END;
        v_debut := chercher_debut_seance(
            a.id_utilisateur, v_lieu, v_jour,
            (a.contenu ->> 'heure_min')::TIME, (a.contenu ->> 'heure_max')::TIME,
            a.duree_minutes, a.discipline, a.intensite, a.groupes, a.id_occurrence);
        v_bloc := bloc_seance_duree(a.id_utilisateur, v_lieu, v_debut, a.duree_minutes);

        UPDATE occurrence o
           SET creneau = NULL, statut = 'a_placer',
               motif = 'Déplacée par une séance de sport'
         WHERE o.id_utilisateur = a.id_utilisateur
           AND o.statut = 'planifiee' AND NOT o.epinglee AND NOT o.rappel_journee
           AND o.origine NOT IN ('quota', 'coach')
           AND o.creneau && v_bloc;

        UPDATE occurrence o
           SET creneau = v_bloc,
               fenetre = tstzrange(LEAST(debut_jour(v_jour), lower(v_bloc)),
                                   GREATEST(debut_jour(v_jour + 1), upper(v_bloc)), '[)'),
               id_lieu = v_lieu, debut_seance = v_debut,
               motif = 'Déplacée sur proposition du coach'
         WHERE o.id_occurrence = a.id_occurrence;
        RETURN;
    END IF;

    -- Alléger ou modifier : le contenu change, la place reste.
    IF a.contenu ? 'exercices' THEN
        v_ids := verifier_exercices(a.id_utilisateur, a.discipline,
                                    a.contenu -> 'exercices', a.jour);
    END IF;
    IF a.discipline <> 'musculation' THEN
        v_groupes := ARRAY['cardio'];
    ELSIF v_ids IS NOT NULL AND cardinality(v_ids) > 0 THEN
        SELECT array_agg(DISTINCT e.groupe_principal) INTO v_groupes
          FROM exercice e WHERE e.id_exercice = ANY (v_ids);
    ELSE
        v_groupes := a.groupes;
    END IF;

    SELECT os.code, os.motif INTO r
      FROM obstacle_sportif(a.id_utilisateur, a.debut_seance, v_intensite, v_groupes,
                            v_ids, a.id_occurrence, TRUE) os
     WHERE os.bloquant LIMIT 1;
    IF FOUND THEN
        PERFORM refus_coach(r.code, r.motif);
    END IF;

    UPDATE seance se
       SET type_seance   = left(COALESCE(a.contenu ->> 'type_seance', se.type_seance), 40),
           intensite     = v_intensite,
           duree_minutes = v_duree,
           groupes       = v_groupes,
           consigne      = CASE WHEN a.contenu ? 'consigne' THEN a.contenu ->> 'consigne'
                                ELSE se.consigne END
     WHERE se.id_occurrence = a.id_occurrence;

    IF v_duree <> a.duree_minutes THEN
        v_bloc := bloc_seance_duree(a.id_utilisateur, a.id_lieu, a.debut_seance, v_duree);
        UPDATE occurrence o
           SET creneau = v_bloc,
               fenetre = tstzrange(LEAST(lower(o.fenetre), lower(v_bloc)),
                                   GREATEST(upper(o.fenetre), upper(v_bloc)), '[)')
         WHERE o.id_occurrence = a.id_occurrence;
    END IF;

    IF a.contenu ? 'exercices' THEN
        PERFORM ecrire_exercices(a.id_occurrence, a.contenu -> 'exercices');
    END IF;
END $$;

COMMENT ON FUNCTION appliquer_ajustement(INTEGER) IS
    'PLN-19 : met en place la version proposée par un ajustement, après avoir
     rejoué les contrôles. La séance reste validée et épinglée.';

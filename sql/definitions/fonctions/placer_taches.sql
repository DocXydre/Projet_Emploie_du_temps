-- -----------------------------------------------------------------------------
-- Le placement enchaîne les trois                               (TAC-12, WKD-3)
--
-- Le placement prépare, pose, puis rapproche. Avant la boucle : ce qu'on fait
-- en rentrant, les occurrences manquantes, les propositions, ce qu'on fait en
-- partant. Après elle : ce qu'une autre tâche couvre, et ce qui va ensemble.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION placer_taches(p_horizon_jours integer DEFAULT 35, p_stabilite_jours integer DEFAULT 7)
 RETURNS integer
 LANGUAGE plpgsql
AS $$
DECLARE
    o         RECORD;
    v_creneau TSTZRANGE;
    v_duree   INTERVAL;
    v_places  INTEGER := 0;
    v_gele    TIMESTAMPTZ;
    v_assigne INTEGER;
    v_lieu    INTEGER;
BEGIN
    -- ABS-8 : ce qu'on refait en rentrant. Avant la génération, pour que la
    -- chaîne de la tâche reparte du retour et non d'une prévision tombée
    -- pendant l'absence.
    PERFORM taches_au_retour(p_horizon_jours);

    PERFORM generer_occurrences(p_horizon_jours);

    -- WKD-3 : une absence vaut réponse à une proposition de week-end. Sans cet
    -- appel, la proposition restait au calendrier alors que le billet était
    -- acheté et l'absence déclarée.
    PERFORM entretenir_propositions();

    -- TAC-12 : ce qui ne peut pas attendre qu'on rentre. L'appel vient avant le
    -- placement, pour que les occurrences créées ici soient placées dans la
    -- foulée.
    PERFORM taches_avant_depart(p_horizon_jours);

    -- PLA-5, PLA-6 : un créneau notifié, épinglé, ou prévu dans les prochains jours
    -- ne bouge plus. Un planning qui change tous les matins ne sert à rien :
    -- on ne peut pas s'organiser autour de quelque chose qui se dérobe.
    v_gele := now() + make_interval(days => p_stabilite_jours);

    -- ABS-5 : exception au gel, quand la personne est absente ce jour-là.
    -- Sans elle, un départ déclaré pour le week-end prochain ne déplacerait
    -- aucune tâche, puisqu'il tombe dans la période gelée.
    UPDATE occurrence
       SET creneau = NULL, statut = 'a_placer', motif = NULL
     WHERE statut = 'planifiee'
       AND NOT epinglee
       -- SPT-23 : une réservation de sport n'est pas à replacer, elle est
       -- tenue par organiser_sport.
       AND origine <> 'quota'
       AND (creneau IS NULL
            OR lower(creneau) > v_gele
            OR (id_utilisateur IS NOT NULL
                AND est_absent(id_utilisateur, jour_de(lower(creneau)))));

    -- TAC-19 : une première fois avant d'attribuer quoi que ce soit, pour que
    -- le ramassage retiré ne compte pas dans le tour de celui qui l'aurait eu.
    PERFORM absorber_les_couvertes();

    -- SPT-23 : les réservations de sport d'abord, le ménage se range autour.
    PERFORM organiser_sport();

    FOR o IN
        SELECT oc.id_occurrence, oc.id_tache, oc.id_utilisateur, oc.fenetre,
               oc.rappel_journee, oc.utilise_machine,
               t.duree_minutes, t.heure_min, t.heure_max,
               t.requiert_les_deux, t.libelle, t.categorie
          FROM occurrence oc
          JOIN tache t ON t.id_tache = oc.id_tache
         WHERE oc.statut = 'a_placer'
           -- Le sport ne passe plus par ici : une séance est choisie, ou
           -- réservée par organiser_sport.
           AND t.categorie <> 'sport'
           AND upper(oc.fenetre) > now()
           AND lower(oc.fenetre) < now() + make_interval(days => p_horizon_jours)
         ORDER BY t.priorite, upper(oc.fenetre), t.duree_minutes DESC
    LOOP
        -- ABS-2 : l'assigné se décide au placement, en fonction de qui est là.
        v_assigne := COALESCE(o.id_utilisateur, choisir_assigne(o.id_tache, o.fenetre));

        IF v_assigne IS NULL THEN
            -- ABS-4 : personne dans l'appartement sur toute la fenêtre. On ne
            -- salit pas ce qu'on n'habite pas : la tâche attend le retour.
            UPDATE occurrence
               SET id_utilisateur = NULL,
                   motif = 'Personne dans l''appartement sur cette période'
             WHERE id_occurrence = o.id_occurrence;
            CONTINUE;
        END IF;

        IF v_assigne IS DISTINCT FROM o.id_utilisateur THEN
            UPDATE occurrence SET id_utilisateur = v_assigne
             WHERE id_occurrence = o.id_occurrence;
        END IF;

        v_duree := make_interval(mins => o.duree_minutes);
        v_lieu := NULL;

        IF o.rappel_journee THEN
            v_creneau := chercher_jour(v_assigne, o.fenetre, v_duree);
        ELSE
            v_creneau := chercher_creneau(v_assigne, o.fenetre, v_duree,
                                          o.heure_min, o.heure_max, o.utilise_machine,
                                          o.requiert_les_deux);
        END IF;

        -- PLA-8 : une occurrence non plaçable n'est jamais supprimée. Elle garde
        -- son statut et reçoit un motif lisible.
        IF v_creneau IS NULL THEN
            UPDATE occurrence
               SET motif = CASE
                               WHEN o.requiert_les_deux THEN
                                   format('Aucun moment où vous êtes libres tous les deux avant le %s',
                                          to_char(upper(o.fenetre) AT TIME ZONE 'Europe/Paris', 'DD/MM'))
                               ELSE
                                   format('Aucune place de %s min avant le %s',
                                          o.duree_minutes,
                                          to_char(upper(o.fenetre) AT TIME ZONE 'Europe/Paris', 'DD/MM'))
                           END
             WHERE id_occurrence = o.id_occurrence;

            -- PLA-9 : aucun créneau commun aux deux personnes. On envoie une
            -- alerte au lieu de placer la tâche à un moment impossible.
            IF o.requiert_les_deux THEN
                INSERT INTO notification (id_utilisateur, id_occurrence, type, contenu)
                SELECT o.id_utilisateur, o.id_occurrence, 'alerte',
                       format('%s : aucun créneau commun trouvé avant le %s.',
                              o.libelle,
                              to_char(upper(o.fenetre) AT TIME ZONE 'Europe/Paris', 'DD/MM'))
                 WHERE o.id_utilisateur IS NOT NULL
                   AND NOT EXISTS (
                       SELECT 1 FROM notification n
                        WHERE n.id_occurrence = o.id_occurrence
                          AND n.statut = 'a_envoyer');
            END IF;
        ELSE
            UPDATE occurrence
               SET creneau = v_creneau,
                   statut  = 'planifiee',
                   id_lieu = v_lieu,
                   motif   = CASE
                                 WHEN v_lieu IS NOT NULL THEN
                                     format('%s le %s, trajet compris',
                                            (SELECT libelle FROM lieu_sport
                                              WHERE id_lieu = v_lieu),
                                            to_char(lower(v_creneau) AT TIME ZONE 'Europe/Paris', 'DD/MM à HH24hMI'))
                                 WHEN o.rappel_journee THEN
                                     format('À faire le %s',
                                            to_char(lower(v_creneau) AT TIME ZONE 'Europe/Paris', 'DD/MM'))
                                 ELSE
                                     format('Placée le %s',
                                            to_char(lower(v_creneau) AT TIME ZONE 'Europe/Paris', 'DD/MM à HH24hMI'))
                             END
             WHERE id_occurrence = o.id_occurrence;

            v_places := v_places + 1;
        END IF;
    END LOOP;

    -- TAC-19 : le vidage vaut ramassage. Une occurrence que couvre une autre
    -- tâche prévue le même jour n'a rien à faire au planning.
    PERFORM absorber_les_couvertes();

    -- TAC-15 à TAC-17 : ce qui va ensemble se fait le même jour. Après le
    -- placement, puisqu'il faut savoir où tombe la tâche qui mène.
    PERFORM poser_les_accompagnements();

    RETURN v_places;
END $$;

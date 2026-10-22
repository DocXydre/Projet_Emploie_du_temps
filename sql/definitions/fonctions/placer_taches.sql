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
    v_regles  BOOLEAN;
    v_autre   INTEGER;
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
       -- PLN-4 : une séance proposée par HAL occupe son créneau. Elle
       -- n'est pas épinglée, mais seul HAL ou l'utilisateur la déplace.
       AND origine <> 'coach'
       AND (creneau IS NULL
            OR lower(creneau) > v_gele
            OR (id_utilisateur IS NOT NULL
                AND est_absent(id_utilisateur, jour_de(lower(creneau))))
            -- CND-9 : un jour qui ne tient plus la règle de la tâche, même
            -- dans les sept jours. Un cours ajouté le seul jour libre du mois
            -- ne laisse pas la tâche y rester.
            OR (id_utilisateur IS NOT NULL
                AND a_des_regles(id_tache)
                AND NOT regles_tiennent(id_tache, id_utilisateur, jour_de(lower(creneau)))));

    -- TAC-19 : une première fois avant d'attribuer quoi que ce soit, pour que
    -- le ramassage retiré ne compte pas dans le tour de celui qui l'aurait eu.
    PERFORM absorber_les_couvertes();

    FOR o IN
        SELECT oc.id_occurrence, oc.id_tache, oc.id_utilisateur, oc.fenetre,
               oc.rappel_journee, oc.utilise_machine,
               t.duree_minutes, t.heure_min, t.heure_max,
               t.requiert_les_deux, t.libelle, t.categorie, t.id_utilisateur_defaut
          FROM occurrence oc
          JOIN tache t ON t.id_tache = oc.id_tache
         WHERE oc.statut = 'a_placer'
           -- Le sport ne passe pas par ici : HAL propose les séances, ou
           -- l'utilisateur les pose (SPT-33).
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
        v_regles := a_des_regles(o.id_tache);

        v_creneau := chercher_place(v_assigne, o.id_tache, o.fenetre);

        -- CND-5 : « un jour où je suis libre » peut ne tenir que pour l'autre.
        -- Une tâche partagée lui revient alors, plutôt que de rester à placer.
        IF v_creneau IS NULL AND v_regles AND o.id_utilisateur_defaut IS NULL
           AND NOT o.requiert_les_deux THEN
            FOR v_autre IN SELECT id_utilisateur FROM utilisateur
                            WHERE actif AND id_utilisateur <> v_assigne
                            ORDER BY id_utilisateur LOOP
                v_creneau := chercher_place(v_autre, o.id_tache, o.fenetre);
                IF v_creneau IS NOT NULL THEN
                    v_assigne := v_autre;
                    UPDATE occurrence SET id_utilisateur = v_assigne
                     WHERE id_occurrence = o.id_occurrence;
                    EXIT;
                END IF;
            END LOOP;
        END IF;

        -- PLA-8 : une occurrence non plaçable n'est jamais supprimée. Elle garde
        -- son statut et reçoit un motif lisible.
        IF v_creneau IS NULL THEN
            UPDATE occurrence
               SET motif = CASE
                               -- CND-12 : la règle n'est jamais assouplie par
                               -- le moteur ; elle se dit dans le motif.
                               WHEN v_regles THEN
                                   format('Aucun jour ne tient sa règle avant le %s',
                                          to_char(upper(o.fenetre) AT TIME ZONE 'Europe/Paris', 'DD/MM'))
                               WHEN o.requiert_les_deux THEN
                                   format('Aucun moment où vous êtes libres tous les deux avant le %s',
                                          to_char(upper(o.fenetre) AT TIME ZONE 'Europe/Paris', 'DD/MM'))
                               ELSE
                                   format('Aucune place de %s min avant le %s',
                                          o.duree_minutes,
                                          to_char(upper(o.fenetre) AT TIME ZONE 'Europe/Paris', 'DD/MM'))
                           END
             WHERE id_occurrence = o.id_occurrence;

            -- RAP-3 : la règle devient impossible ; son rappel est dû, une
            -- fois par jour au plus (RAP-5).
            IF v_regles THEN
                UPDATE rappel_hal
                   SET declenche_le = now()
                 WHERE etat = 'attente'
                   AND evenement = 'impossible'
                   AND id_regle_tache IN (SELECT id_regle_tache FROM regle_tache
                                           WHERE id_tache = o.id_tache AND etat = 'active')
                   AND (declenche_le IS NULL OR declenche_le < debut_jour(jour_de(now())));
            END IF;

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
                   -- CND-8 : la règle qui a décidé du jour, la plus ancienne
                   -- s'il y en a plusieurs.
                   id_regle_tache = CASE WHEN v_regles THEN
                                        (SELECT min(id_regle_tache) FROM regle_tache
                                          WHERE id_tache = o.id_tache AND etat = 'active')
                                    END,
                   motif   = CASE
                                 WHEN v_lieu IS NOT NULL THEN
                                     format('%s le %s, trajet compris',
                                            (SELECT libelle FROM lieu_sport
                                              WHERE id_lieu = v_lieu),
                                            to_char(lower(v_creneau) AT TIME ZONE 'Europe/Paris', 'DD/MM à HH24hMI'))
                                 WHEN o.rappel_journee AND v_regles THEN
                                     format('À faire le %s, selon sa règle',
                                            to_char(lower(v_creneau) AT TIME ZONE 'Europe/Paris', 'DD/MM'))
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

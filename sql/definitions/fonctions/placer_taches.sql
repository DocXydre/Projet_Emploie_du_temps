-- -----------------------------------------------------------------------------
-- Le placement enchaîne les trois                         (opération 4, WKD-3)
--
-- Le placement prépare, pose, puis rapproche. Avant la boucle : les
-- occurrences manquantes et les propositions. Après elle : ce qu'une autre
-- tâche couvre, et ce qui va ensemble. Ce que les descriptions demandent de
-- plus (avant un départ, au retour), c'est HAL qui le pose (VER-10).
-- RGL-7 : une tâche à plusieurs se pose sur un créneau commun, avec tous ses participants.
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
    v_membres INTEGER;
    v_ids     INTEGER[];
    v_jour    DATE;
    v_dernier DATE;
    v_plage   TSTZRANGE;
    v_dispo   TSTZRANGE;
    v_phrase  TEXT;
BEGIN
    PERFORM generer_occurrences(p_horizon_jours);

    -- WKD-3 : une absence vaut réponse à une proposition de week-end. Sans cet
    -- appel, la proposition restait au calendrier alors que le billet était
    -- acheté et l'absence déclarée.
    PERFORM entretenir_propositions();

    -- PLA-5, PLA-6 : un créneau notifié, épinglé, ou prévu dans les prochains jours
    -- ne bouge plus. Un planning qui change tous les matins ne sert à rien :
    -- on ne peut pas s'organiser autour de quelque chose qui se dérobe.
    v_gele := now() + make_interval(days => p_stabilite_jours);

    -- VER-2 : ce que HAL a épinglé un jour où la personne n'est pas là redevient
    -- au moteur, qui le replace ; HAL le relira.
    UPDATE occurrence
       SET epinglee = FALSE
     WHERE epinglee_par = 'hal'
       AND statut = 'planifiee'
       AND creneau IS NOT NULL
       AND id_utilisateur IS NOT NULL
       AND est_absent(id_utilisateur, jour_de(lower(creneau)));

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
                AND est_absent(id_utilisateur, jour_de(lower(creneau)))));

    -- RGL-7 : une occurrence qui ne correspond plus à la règle de sa tâche (règle
    -- posée ou retirée depuis son placement) repart au placement, gel ou non : une
    -- règle vaut tout de suite pour ce qui vient. Une occurrence épinglée, déjà
    -- annoncée ou proposée par HAL reste où elle est. Si le foyer a moins de
    -- membres actifs que la règle n'en demande, la règle ne joue pas.
    UPDATE occurrence oc
       SET creneau = NULL, statut = 'a_placer', motif = NULL, id_utilisateur = NULL
     WHERE oc.statut = 'planifiee'
       AND NOT oc.epinglee
       AND oc.origine <> 'coach'
       AND oc.creneau IS NOT NULL
       AND lower(oc.creneau) > now()
       AND COALESCE(membres_a_plusieurs(oc.id_tache)
                    <= (SELECT count(*) FROM utilisateur WHERE actif), FALSE)
           <> EXISTS (SELECT 1 FROM occurrence_participant p
                       WHERE p.id_occurrence = oc.id_occurrence)
       AND NOT EXISTS (SELECT 1 FROM notification n
                        WHERE n.id_occurrence = oc.id_occurrence
                          AND n.statut IN ('a_envoyer', 'envoyee'));

    -- Une occurrence à replacer n'a plus de participants : ils se refont avec son créneau.
    DELETE FROM occurrence_participant p
     USING occurrence oc
     WHERE oc.id_occurrence = p.id_occurrence
       AND oc.statut = 'a_placer';

    -- TAC-19 : une première fois avant d'attribuer quoi que ce soit, pour que
    -- le ramassage retiré ne compte pas dans le tour de celui qui l'aurait eu.
    PERFORM absorber_les_couvertes();

    FOR o IN
        SELECT oc.id_occurrence, oc.id_tache, oc.id_utilisateur, oc.fenetre,
               oc.rappel_journee,
               t.duree_minutes, t.heure_min, t.heure_max, t.libelle
          FROM occurrence oc
          JOIN tache t ON t.id_tache = oc.id_tache
         WHERE oc.statut = 'a_placer'
           -- Le sport ne passe pas par ici : HAL propose les séances, ou
           -- l'utilisateur les pose (SPT-33).
           AND t.id_type_tache IS NOT NULL
           AND upper(oc.fenetre) > now()
           AND lower(oc.fenetre) < now() + make_interval(days => p_horizon_jours)
         ORDER BY t.priorite, upper(oc.fenetre), t.duree_minutes DESC
    LOOP
        -- RGL-7 : une tâche à plusieurs ne se pose que sur un créneau où tous les
        -- membres actifs sont présents et libres ; tous deviennent participants et
        -- le premier (plus petit id_utilisateur) reste l'assigné de l'occurrence.
        v_membres := membres_a_plusieurs(o.id_tache);
        v_ids := NULL;
        IF v_membres IS NOT NULL THEN
            SELECT array_agg(id_utilisateur ORDER BY id_utilisateur) INTO v_ids
              FROM utilisateur WHERE actif;
        END IF;

        IF v_membres IS NOT NULL AND COALESCE(cardinality(v_ids), 0) >= v_membres THEN
            v_duree   := make_interval(mins => o.duree_minutes);
            v_creneau := NULL;
            v_jour    := GREATEST(jour_de(lower(o.fenetre)), jour_de(now()));
            v_dernier := jour_de(upper(o.fenetre) - INTERVAL '1 second');

            WHILE v_jour <= v_dernier AND v_creneau IS NULL LOOP
                -- ABS-2 : pas de jour où l'un des membres n'est pas là.
                IF NOT EXISTS (SELECT 1 FROM unnest(v_ids) AS m(id) WHERE est_absent(m.id, v_jour)) THEN
                    IF o.rappel_journee THEN
                        IF NOT EXISTS (SELECT 1 FROM unnest(v_ids) AS m(id)
                                        WHERE temps_libre_jour(m.id, v_jour) < v_duree) THEN
                            v_creneau := tstzrange(debut_jour(v_jour), debut_jour(v_jour + 1), '[)');
                        END IF;
                    ELSE
                        v_plage := tstzrange((v_jour + o.heure_min) AT TIME ZONE 'Europe/Paris',
                                             (v_jour + COALESCE(o.heure_max, TIME '23:59:59')) AT TIME ZONE 'Europe/Paris',
                                             '[)')
                                   * o.fenetre
                                   * tstzrange(now(), NULL, '[)');
                        IF NOT isempty(v_plage) THEN
                            FOR v_dispo IN
                                SELECT d FROM disponibilites_communes(lower(v_plage), upper(v_plage)) d
                                 ORDER BY lower(d)
                            LOOP
                                IF upper(v_dispo) - lower(v_dispo) >= v_duree THEN
                                    v_creneau := tstzrange(lower(v_dispo), lower(v_dispo) + v_duree, '[)');
                                    EXIT;
                                END IF;
                            END LOOP;
                        END IF;
                    END IF;
                END IF;
                v_jour := v_jour + 1;
            END LOOP;

            IF v_creneau IS NULL THEN
                -- RGL-7, PLA-8 : sans créneau commun, l'occurrence reste à placer,
                -- sans assigné, avec la règle pour motif.
                SELECT r.phrase INTO v_phrase
                  FROM regle r
                 WHERE r.id_tache = o.id_tache AND r.sorte = 'a_plusieurs' AND r.etat = 'active'
                 ORDER BY r.id_regle DESC
                 LIMIT 1;

                UPDATE occurrence
                   SET id_utilisateur = NULL,
                       motif = format('Règle « %s » : aucun créneau de %s min où tous sont présents et libres avant le %s',
                                      COALESCE(v_phrase, 'Ça se fait à deux.'), o.duree_minutes,
                                      to_char(upper(o.fenetre) AT TIME ZONE 'Europe/Paris', 'DD/MM'))
                 WHERE id_occurrence = o.id_occurrence;
            ELSE
                UPDATE occurrence
                   SET id_utilisateur = v_ids[1],
                       creneau = v_creneau,
                       statut  = 'planifiee',
                       motif   = CASE WHEN o.rappel_journee THEN
                                          format('À faire le %s, ensemble',
                                                 to_char(lower(v_creneau) AT TIME ZONE 'Europe/Paris', 'DD/MM'))
                                      ELSE
                                          format('Placée le %s, ensemble',
                                                 to_char(lower(v_creneau) AT TIME ZONE 'Europe/Paris', 'DD/MM à HH24hMI'))
                                 END
                 WHERE id_occurrence = o.id_occurrence;

                INSERT INTO occurrence_participant (id_occurrence, id_utilisateur)
                SELECT o.id_occurrence, m.id FROM unnest(v_ids) AS m(id);

                v_places := v_places + 1;
            END IF;
            CONTINUE;
        END IF;

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
                                          o.heure_min, o.heure_max);
        END IF;

        -- PLA-8 : une occurrence non plaçable n'est jamais supprimée. Elle garde
        -- son statut et reçoit un motif lisible.
        IF v_creneau IS NULL THEN
            UPDATE occurrence
               SET motif = format('Aucune place de %s min avant le %s',
                                  o.duree_minutes,
                                  to_char(upper(o.fenetre) AT TIME ZONE 'Europe/Paris', 'DD/MM'))
             WHERE id_occurrence = o.id_occurrence;
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

    -- TAC-15, TAC-16 : ce qui va ensemble se fait le même jour. Après le
    -- placement, puisqu'il faut savoir où tombe la tâche qui mène.
    PERFORM poser_les_accompagnements();

    -- VER-3 : ce que le moteur crée ou déplace n'entre pas dans la file des
    -- vérifications. Il replace après chaque geste et chaque matin : la file
    -- appelait HAL à chaque fois, même derrière la vérification de la semaine,
    -- qui relit tout (VER-5). Seul un changement de l'emploi du temps la remplit.

    RETURN v_places;
END $$;

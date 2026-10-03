-- -----------------------------------------------------------------------------
-- Le bilan du matin montre la journée entière                         (NOT-4)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bilan_du_matin() RETURNS INTEGER
LANGUAGE plpgsql AS $$
DECLARE
    u          RECORD;
    o          RECORD;
    v_lignes   TEXT[];
    v_retards  TEXT[];
    v_bloquees TEXT[];
    v_pannes   TEXT[];
    v_contenu  TEXT;
    v_envoyees INTEGER := 0;
    v_jour     DATE := jour_de(now());
BEGIN
    -- ORDER BY explicite, pour que la sortie soit toujours la même.
    FOR u IN SELECT id_utilisateur, pseudo, role FROM utilisateur WHERE actif
              ORDER BY id_utilisateur LOOP
        v_lignes   := ARRAY[]::TEXT[];
        v_retards  := ARRAY[]::TEXT[];
        v_bloquees := ARRAY[]::TEXT[];
        v_pannes   := ARRAY[]::TEXT[];

        -- Ce qui est prévu aujourd'hui, tout compris : cours, services,
        -- tâches, propositions. NOT-4 : le bilan ne lisait que les tâches, et
        -- une journée de cours n'y apparaissait pas alors qu'elle figurait dans
        -- « /planning » et sur le téléphone. `v_planning` est la vue qui fait
        -- déjà cette fusion, autant s'en servir plutôt que de la refaire.
        FOR o IN
            SELECT p.nature, p.id, p.libelle, p.debut, p.fin,
                   p.journee_entiere, p.lieu, p.nb_relances
              FROM v_planning p
             WHERE p.id_utilisateur = u.id_utilisateur
               AND p.debut < debut_jour(v_jour + 1)
               AND p.fin   > debut_jour(v_jour)
             ORDER BY p.journee_entiere, p.debut
        LOOP
            v_lignes := v_lignes || (
                CASE WHEN o.journee_entiere
                     THEN '• ' || o.libelle
                     ELSE '• ' || to_char(o.debut AT TIME ZONE 'Europe/Paris', 'HH24hMI')
                          || '–' || to_char(o.fin AT TIME ZONE 'Europe/Paris', 'HH24hMI')
                          || ' ' || o.libelle
                END
                || COALESCE(' — ' || o.lieu, '')
                || CASE WHEN o.nature = 'tache' AND COALESCE(o.nb_relances, 0) > 0
                        THEN ' (en retard depuis ' || o.nb_relances || ' j)'
                        ELSE '' END);

            -- Le créneau communiqué est figé (PLA-5). Un cours n'a pas de
            -- statut à figer, la règle ne vaut que pour les tâches.
            IF o.nature = 'tache' THEN
                UPDATE occurrence SET statut = 'notifiee'
                 WHERE id_occurrence = o.id AND statut = 'planifiee';
            END IF;
        END LOOP;

        -- Ce qui traîne.
        SELECT array_agg('• ' || tache_libelle || ' (' || jours_de_retard || ' j)'
                         ORDER BY jours_de_retard DESC)
          INTO v_retards
          FROM v_occurrence
         WHERE id_utilisateur = u.id_utilisateur
           AND en_retard
           AND (creneau IS NULL OR jour_de(debut) <> v_jour);

        -- Ce que le moteur n'a pas su placer, et sur quoi on peut encore agir.
        -- PLA-11 : une échéance à moins de deux jours ne se rattrape plus en
        -- réorganisant sa semaine, et une échéance à plus d'une semaine n'est
        -- pas encore un problème. Entre les deux, la liste sert à quelque chose.
        SELECT array_agg('• ' || tache_libelle || ' : ' || motif
                         ORDER BY echeance_max)
          INTO v_bloquees
          FROM v_occurrence
         WHERE id_utilisateur = u.id_utilisateur
           AND statut = 'a_placer'
           AND motif IS NOT NULL
           AND echeance_max BETWEEN now() + INTERVAL '2 days'
                                AND now() + INTERVAL '7 days';

        -- Les pannes de collecte ne concernent que l'administrateur.
        IF u.role = 'admin' THEN
            SELECT array_agg('• ' || libelle)
              INTO v_pannes
              FROM v_source_sante
             WHERE etat_calcule = 'en_panne' AND active;
        END IF;

        v_contenu := '';
        IF array_length(v_lignes, 1) > 0 THEN
            v_contenu := 'Aujourd''hui :' || E'\n' || array_to_string(v_lignes, E'\n');
        END IF;
        IF array_length(v_retards, 1) > 0 THEN
            v_contenu := v_contenu || CASE WHEN v_contenu = '' THEN '' ELSE E'\n\n' END
                         || 'En retard :' || E'\n' || array_to_string(v_retards, E'\n');
        END IF;
        IF array_length(v_bloquees, 1) > 0 THEN
            v_contenu := v_contenu || CASE WHEN v_contenu = '' THEN '' ELSE E'\n\n' END
                         || 'Sans créneau :' || E'\n' || array_to_string(v_bloquees, E'\n');
        END IF;
        IF array_length(v_pannes, 1) > 0 THEN
            v_contenu := v_contenu || CASE WHEN v_contenu = '' THEN '' ELSE E'\n\n' END
                         || 'Collecte en panne :' || E'\n' || array_to_string(v_pannes, E'\n');
        END IF;

        -- Pas de bilan quand il n'y a rien à dire.
        IF v_contenu <> '' THEN
            INSERT INTO notification (id_utilisateur, type, contenu)
            VALUES (u.id_utilisateur, 'bilan', v_contenu);
            v_envoyees := v_envoyees + 1;
        END IF;
    END LOOP;

    RETURN v_envoyees;
END $$;

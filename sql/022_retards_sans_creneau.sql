-- rejouable : ce fichier ne contient que des CREATE OR REPLACE.
-- =============================================================================
-- 022 : le retard qui ne se place jamais, et le bilan qui sert à quelque chose
--                                                          (EXE-12, PLA-11)
--
-- Deux trous se voyaient dans le bilan du matin.
--
-- Le premier : une occurrence que le moteur n'a jamais réussi à placer reste
-- « à placer », sans créneau. Le report d'office ne regardait que les tâches
-- posées, donc celles-là n'étaient jamais reportées, jamais abandonnées, et
-- s'empilaient. Sept lessives de travail au même jour de retard, une douzaine
-- de séances de sport : ce n'est pas un retard, c'est une accumulation que
-- personne ne rattrapera.
--
-- Le second : la liste « Sans créneau » montrait tout, y compris des échéances
-- dépassées depuis deux semaines. Une information sur laquelle on ne peut plus
-- agir n'est pas une information, c'est du bruit qui fait sauter la lecture du
-- bilan entier.
--
-- Rien ici ne touche aux occupations : ni les cours, ni les shifts. L'emploi du
-- temps collecté se garde en entier, c'est la mémoire de ce qu'on a fait.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Abandonner une occurrence                                            (EXE-12)
--
-- Écrite une fois : deux passes l'appellent, et deux copies auraient divergé.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION abandonner_occurrence(p_occurrence INTEGER,
                                                 p_jours INTEGER)
RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE
    v_libelle      TEXT;
    v_utilisateur  INTEGER;
BEGIN
    SELECT t.libelle, oc.id_utilisateur INTO v_libelle, v_utilisateur
      FROM occurrence oc JOIN tache t ON t.id_tache = oc.id_tache
     WHERE oc.id_occurrence = p_occurrence;

    UPDATE occurrence
       SET statut  = 'abandonnee',
           creneau = NULL,
           motif   = format('Oubliée après %s jour(s) de retard', p_jours)
     WHERE id_occurrence = p_occurrence;

    INSERT INTO notification (id_utilisateur, id_occurrence, type, contenu)
    VALUES (v_utilisateur, p_occurrence, 'alerte',
            format('%s abandonnée : %s jour(s) de retard. La prochaine '
                   'occurrence suivra son cours.', v_libelle, p_jours));
END $$;


-- -----------------------------------------------------------------------------
-- Report d'office, étendu à ce qui n'a jamais eu de créneau           (EXE-12)
-- -----------------------------------------------------------------------------
DROP FUNCTION IF EXISTS reporter_taches_du_jour();

CREATE FUNCTION reporter_taches_du_jour() RETURNS JSONB
LANGUAGE plpgsql AS $$
DECLARE
    o             RECORD;
    v_reportees   INTEGER := 0;
    v_abandonnees INTEGER := 0;
    v_alertes     INTEGER := 0;
    v_demain      DATE := jour_de(now()) + 1;
BEGIN
    -- 1. Ce qui avait un créneau et n'a pas été fait.
    FOR o IN
        SELECT oc.id_occurrence, oc.id_utilisateur, oc.creneau, oc.fenetre,
               oc.rappel_journee,
               t.reportable, t.libelle, t.abandon_apres_jours,
               v.jours_de_retard
          FROM occurrence oc
          JOIN tache t        ON t.id_tache = oc.id_tache
          JOIN v_occurrence v ON v.id_occurrence = oc.id_occurrence
         WHERE oc.statut IN ('planifiee', 'notifiee')
           AND oc.creneau IS NOT NULL
           AND upper(oc.creneau) <= now()
    LOOP
        IF o.abandon_apres_jours > 0 AND o.jours_de_retard >= o.abandon_apres_jours THEN
            PERFORM abandonner_occurrence(o.id_occurrence, o.jours_de_retard);
            v_abandonnees := v_abandonnees + 1;
            CONTINUE;
        END IF;

        -- Une lessive de travail en retard ne se reporte pas : le report ne
        -- résout rien, il faut le savoir tout de suite. Le compteur avance
        -- quand même, sans quoi elle paraîtrait à l'heure et ne serait jamais
        -- abandonnée.
        IF NOT o.reportable THEN
            UPDATE occurrence SET nb_relances = nb_relances + 1
             WHERE id_occurrence = o.id_occurrence;

            INSERT INTO notification (id_utilisateur, id_occurrence, type, contenu)
            VALUES (o.id_utilisateur, o.id_occurrence, 'alerte',
                    format('%s non faite et non reportable.', o.libelle));

            v_alertes := v_alertes + 1;
            CONTINUE;
        END IF;

        UPDATE occurrence
           SET creneau     = NULL,
               statut      = 'a_placer',
               nb_relances = nb_relances + 1,
               fenetre     = fenetre_pour(o.rappel_journee,
                                          lower(o.fenetre),
                                          GREATEST(upper(o.fenetre), debut_jour(v_demain + 1))),
               motif       = 'Reportée au lendemain, non faite'
         WHERE id_occurrence = o.id_occurrence;

        v_reportees := v_reportees + 1;
    END LOOP;

    -- 2. Ce qui n'a jamais trouvé de place et dont l'échéance est passée. Sans
    -- cette passe, une occurrence jamais posée n'était jamais vue par le report
    -- et restait indéfiniment dans la liste.
    FOR o IN
        SELECT oc.id_occurrence, v.jours_de_retard
          FROM occurrence oc
          JOIN tache t        ON t.id_tache = oc.id_tache
          JOIN v_occurrence v ON v.id_occurrence = oc.id_occurrence
         WHERE oc.statut = 'a_placer'
           AND upper(oc.fenetre) < now()
           AND t.abandon_apres_jours > 0
           AND v.jours_de_retard >= t.abandon_apres_jours
    LOOP
        PERFORM abandonner_occurrence(o.id_occurrence, o.jours_de_retard);
        v_abandonnees := v_abandonnees + 1;
    END LOOP;

    RETURN jsonb_build_object('reportees',   v_reportees,
                              'abandonnees', v_abandonnees,
                              'alertes',     v_alertes);
END $$;

COMMENT ON FUNCTION reporter_taches_du_jour IS
    'Report d''office de minuit. Reporte, abandonne au-delà du délai de la
     tâche, ou alerte pour une tâche non reportable. Traite aussi ce qui n''a
     jamais eu de créneau. Rend le compte des trois.';


-- -----------------------------------------------------------------------------
-- Bilan du matin : « Sans créneau » borné à ce sur quoi on peut agir  (PLA-11)
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

        -- Ce qui est prévu aujourd'hui.
        FOR o IN
            SELECT oc.id_occurrence, oc.creneau, oc.rappel_journee, oc.nb_relances,
                   t.libelle
              FROM occurrence oc
              JOIN tache t ON t.id_tache = oc.id_tache
             WHERE oc.id_utilisateur = u.id_utilisateur
               AND oc.statut IN ('planifiee', 'notifiee')
               AND oc.creneau IS NOT NULL
               AND jour_de(lower(oc.creneau)) = v_jour
             ORDER BY lower(oc.creneau)
        LOOP
            v_lignes := v_lignes || (
                CASE WHEN o.rappel_journee
                     THEN '• ' || o.libelle
                     ELSE '• ' || to_char(lower(o.creneau) AT TIME ZONE 'Europe/Paris', 'HH24hMI')
                          || ' ' || o.libelle
                END
                || CASE WHEN o.nb_relances > 0
                        THEN ' (en retard depuis ' || o.nb_relances || ' j)'
                        ELSE '' END);

            -- Le créneau communiqué est figé (PLA-5).
            UPDATE occurrence SET statut = 'notifiee'
             WHERE id_occurrence = o.id_occurrence AND statut = 'planifiee';
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

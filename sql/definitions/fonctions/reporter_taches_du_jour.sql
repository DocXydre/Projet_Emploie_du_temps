-- -----------------------------------------------------------------------------
-- Le report de minuit ne reporte pas une séance                        (SPT-25)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION reporter_taches_du_jour()
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
    o             RECORD;
    v_reportees   INTEGER := 0;
    v_abandonnees INTEGER := 0;
    v_alertes     INTEGER := 0;
    v_demain      DATE := jour_de(now()) + 1;
BEGIN
    -- SPT-25 : les réservations de sport passées sont constatées d'abord,
    -- au cas où l'ordonnanceur ne l'aurait pas fait dans la journée.
    PERFORM seances_a_determiner_passees();

    -- 1. Ce qui avait un créneau et n'a pas été fait.
    FOR o IN
        SELECT oc.id_occurrence, oc.id_utilisateur, oc.creneau, oc.fenetre,
               oc.rappel_journee,
               t.reportable, t.libelle, t.abandon_apres_jours, t.categorie,
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

        -- SPT-25 : une séance choisie ne se reporte pas au lendemain. Elle
        -- attend sa réponse, faite ou pas faite, jusqu'à l'abandon.
        CONTINUE WHEN o.categorie = 'sport';

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
END $function$;

COMMENT ON FUNCTION reporter_taches_du_jour IS
    'Report d''office de minuit. Reporte, abandonne au-delà du délai de la
     tâche, ou alerte pour une tâche non reportable. Traite aussi ce qui n''a
     jamais eu de créneau. Rend le compte des trois.';

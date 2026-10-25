-- -----------------------------------------------------------------------------
-- Le report de minuit                                (EXE-6, TAC-24, EXE-12)
--
-- Chaque tâche dit ce qu'elle devient si elle n'est pas faite à temps (TAC-24) :
-- reportée au lendemain, jusqu'à être faite ou refusée, ou oubliée une fois sa
-- fenêtre passée. Une séance ne se reporte pas (SPT-25) : sans nouvelle d'un
-- compte sans HAL, elle est abandonnée au bout de trois jours (EXE-12).
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION reporter_taches_du_jour()
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
    o             RECORD;
    v_reportees   INTEGER := 0;
    v_abandonnees INTEGER := 0;
    v_oubliees    INTEGER := 0;
    v_alertes     INTEGER := 0;
    v_demain      DATE := jour_de(now()) + 1;
    -- EXE-12 : une séance ne se rattrape pas.
    SEANCE_ABANDONNEE_APRES CONSTANT INTEGER := 3;
BEGIN
    -- 1. Ce qui avait un créneau et n'a pas été fait.
    FOR o IN
        SELECT oc.id_occurrence, oc.id_utilisateur, oc.creneau, oc.fenetre,
               oc.rappel_journee,
               t.libelle, t.id_type_tache IS NULL AS sport,
               t.si_pas_faite, v.jours_de_retard
          FROM occurrence oc
          JOIN tache t        ON t.id_tache = oc.id_tache
          JOIN v_occurrence v ON v.id_occurrence = oc.id_occurrence
         WHERE oc.statut IN ('planifiee', 'notifiee')
           AND oc.creneau IS NOT NULL
           AND upper(oc.creneau) <= now()
    LOOP
        -- TAC-24 : sa fenêtre est passée, et elle demande d'être oubliée.
        IF NOT o.sport AND o.si_pas_faite = 'oublier' AND upper(o.fenetre) <= now() THEN
            PERFORM oublier_occurrence(o.id_occurrence);
            v_oubliees := v_oubliees + 1;
            CONTINUE;
        END IF;

        -- SPT-25 : une séance choisie ne se reporte pas au lendemain. Elle
        -- attend sa réponse, faite ou pas faite, jusqu'à l'abandon.
        IF o.sport THEN
            IF o.jours_de_retard >= SEANCE_ABANDONNEE_APRES THEN
                PERFORM abandonner_occurrence(o.id_occurrence, o.jours_de_retard);
                v_abandonnees := v_abandonnees + 1;
            END IF;
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

    -- 2. Ce qui n'a jamais trouvé de place et dont l'échéance est passée.
    --
    -- Une tâche à oublier l'est d'abord, sans attendre de délai de retard.
    FOR o IN
        SELECT oc.id_occurrence
          FROM occurrence oc
          JOIN tache t ON t.id_tache = oc.id_tache
         WHERE oc.statut IN ('a_placer', 'planifiee', 'notifiee')
           AND t.si_pas_faite = 'oublier'
           AND t.id_type_tache IS NOT NULL
           AND upper(oc.fenetre) <= now()
    LOOP
        PERFORM oublier_occurrence(o.id_occurrence);
        v_oubliees := v_oubliees + 1;
    END LOOP;

    -- Une séance jamais posée attend aussi ses trois jours. Une tâche à reporter,
    -- elle, reste jusqu'à être faite ou refusée (TAC-24).
    FOR o IN
        SELECT oc.id_occurrence, v.jours_de_retard
          FROM occurrence oc
          JOIN tache t        ON t.id_tache = oc.id_tache
          JOIN v_occurrence v ON v.id_occurrence = oc.id_occurrence
         WHERE oc.statut = 'a_placer'
           AND upper(oc.fenetre) < now()
           AND t.id_type_tache IS NULL
           AND v.jours_de_retard >= SEANCE_ABANDONNEE_APRES
    LOOP
        PERFORM abandonner_occurrence(o.id_occurrence, o.jours_de_retard);
        v_abandonnees := v_abandonnees + 1;
    END LOOP;

    RETURN jsonb_build_object('reportees',   v_reportees,
                              'abandonnees', v_abandonnees,
                              'oubliees',    v_oubliees,
                              'alertes',     v_alertes);
END $function$;

COMMENT ON FUNCTION reporter_taches_du_jour IS
    'Report d''office de minuit. Reporte ou oublie chaque tâche selon ce
     qu''elle dit (TAC-24), abandonne une séance sans nouvelle au bout de trois
     jours (EXE-12). Traite aussi ce qui n''a jamais eu de créneau. Rend le
     compte de chacun.';

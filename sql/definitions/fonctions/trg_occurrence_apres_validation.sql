-- Valider une lessive ne met plus rien à sécher (ancienne UNI-13).
CREATE OR REPLACE FUNCTION trg_occurrence_apres_validation()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
DECLARE
    t          RECORD;
    e          RECORD;
    v_cible    RECORD;
    v_depart   TIMESTAMPTZ;
    v_limite   TIMESTAMPTZ;
    v_existante INTEGER;
BEGIN
    SELECT * INTO t FROM tache WHERE id_tache = NEW.id_tache;

    -- ---- Les prévisions deviennent fausses ----------------------------------
    --
    -- Les occurrences pré-générées étaient calculées en supposant la tâche
    -- faite en fin de fenêtre. La validation donne la vraie date : on efface
    -- les suivantes et on les régénère. Une prévision jamais annoncée n'a pas
    -- à laisser de trace.
    DELETE FROM occurrence
     WHERE id_tache = NEW.id_tache
       AND id_occurrence <> NEW.id_occurrence
       AND origine = 'recurrence'
       AND statut IN ('a_placer', 'planifiee')
       AND NOT epinglee;

    -- ---- EXE-1 : l'occurrence suivante part de la date réelle ------------------
    IF t.active AND t.recurrente THEN
        INSERT INTO occurrence (id_tache, id_utilisateur, fenetre, origine,
                                id_occurrence_source)
        VALUES (t.id_tache,
                t.id_utilisateur_defaut,
                fenetre_pour(t.rappel_journee,
                             NEW.date_faite + make_interval(days => t.periodicite_min_jours),
                             NEW.date_faite + make_interval(days => t.periodicite_max_jours)),
                'recurrence',
                NEW.id_occurrence);
    END IF;

    -- ---- EXE-2, EXE-3 : enchaînements, sans doublon et jamais avant la source ----
    FOR e IN SELECT * FROM enchainement WHERE id_tache_source = NEW.id_tache LOOP

        SELECT * INTO v_cible FROM tache WHERE id_tache = e.id_tache_suivante;
        CONTINUE WHEN NOT v_cible.active;

        -- Le délai minimum décale le début de la fenêtre : le linge étendu ce
        -- soir ne se plie pas dans la foulée, mais le lendemain.
        v_depart := NEW.date_faite + make_interval(hours => e.delai_min_heures);
        v_limite := NEW.date_faite + make_interval(hours => e.delai_max_heures);

        SELECT id_occurrence INTO v_existante
          FROM occurrence
         WHERE id_tache = e.id_tache_suivante
           AND statut IN ('a_placer', 'planifiee', 'notifiee')
           AND fenetre && tstzrange(v_depart, v_limite, '[)')
         ORDER BY upper(fenetre)
         LIMIT 1;

        IF v_existante IS NOT NULL THEN
            -- Anti-doublon : on repositionne au lieu de créer une deuxième
            -- occurrence de la même tâche.
            UPDATE occurrence
               SET fenetre = fenetre_pour(v_cible.rappel_journee, v_depart, v_limite),
                   creneau = NULL,
                   statut  = 'a_placer',
                   motif   = format('Repositionnée après %s', t.code)
             WHERE id_occurrence = v_existante;
        ELSE
            INSERT INTO occurrence (id_tache, id_utilisateur, fenetre, origine,
                                    id_occurrence_source, motif)
            VALUES (v_cible.id_tache,
                    v_cible.id_utilisateur_defaut,
                    fenetre_pour(v_cible.rappel_journee, v_depart, v_limite),
                    'enchainement',
                    NEW.id_occurrence,
                    format('Déclenchée par %s', t.code));
        END IF;
    END LOOP;

    -- ---- TAC-10 : faire ceci vaut avoir fait cela ------------------------------
    --
    -- L'occurrence couverte est marquée faite à la même date. Ce trigger se
    -- redéclenche alors pour elle, ce qui recrée sa suivante au bon moment :
    -- vider la litière un mardi repousse le prochain ramassage au jeudi.
    FOR e IN SELECT id_tache_couverte FROM remplacement WHERE id_tache_faite = NEW.id_tache LOOP
        UPDATE occurrence
           SET statut     = 'faite',
               date_faite = NEW.date_faite,
               motif      = format('Couverte par %s', t.code)
         WHERE id_tache = e.id_tache_couverte
           AND statut IN ('a_placer', 'planifiee', 'notifiee');
    END LOOP;

    RETURN NULL;
END $function$;

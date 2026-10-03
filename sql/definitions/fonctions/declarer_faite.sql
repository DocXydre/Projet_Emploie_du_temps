-- -----------------------------------------------------------------------------
-- Déclarer une tâche qui n'était pas la sienne                         (EXE-15)
--
-- `declarer_faite` ne reprenait que les occurrences sans assigné ou assignées à
-- l'appelant : déclarer une tâche prévue pour l'autre en créait une deuxième,
-- et la sienne restait au planning. On reprend désormais la plus proche, quel
-- que soit son assigné, et la validation la recrédite (EXE-14).
--
-- Au passage, la fonction ne fonctionnait plus du tout : elle lisait et
-- écrivait `echeance_min` et `echeance_max`, deux colonnes remplacées depuis
-- par la fenêtre. Toute déclaration spontanée échouait donc, et rien ne le
-- disait faute de test. C'est corrigé ici, et testé.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION declarer_faite(
    p_utilisateur INTEGER,
    p_code_tache  VARCHAR,
    p_quand       TIMESTAMPTZ DEFAULT NULL
) RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE
    t            RECORD;
    v_occurrence INTEGER;
    v_quand      TIMESTAMPTZ := COALESCE(p_quand, now());
BEGIN
    SELECT * INTO t FROM tache WHERE code = p_code_tache AND active;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Tâche % inconnue ou inactive', p_code_tache
              USING ERRCODE = 'no_data_found';
    END IF;

    IF v_quand > now() THEN
        RAISE EXCEPTION 'On ne déclare pas fait ce qui ne l''est pas encore'
              USING ERRCODE = 'check_violation';
    END IF;

    -- La plus proche d'abord : si deux occurrences traînent, c'est celle dont
    -- l'échéance approche que l'on vient de faire. L'assigné n'entre plus dans
    -- le choix : une tâche faite est une tâche faite.
    SELECT id_occurrence INTO v_occurrence
      FROM occurrence
     WHERE id_tache = t.id_tache
       AND statut IN ('a_placer', 'planifiee', 'notifiee')
       -- Une séance de sport à déterminer ne se déclare pas : elle se choisit.
       AND origine <> 'quota'
     ORDER BY upper(fenetre)
     LIMIT 1;

    IF v_occurrence IS NULL THEN
        INSERT INTO occurrence (id_tache, id_utilisateur, fenetre, statut, origine, motif)
        VALUES (t.id_tache, p_utilisateur,
                fenetre_pour(t.rappel_journee, v_quand,
                             v_quand + make_interval(days => t.periodicite_max_jours)),
                'a_placer', 'manuelle', 'Déclarée faite hors planning')
        RETURNING id_occurrence INTO v_occurrence;
    END IF;

    PERFORM valider_occurrence(v_occurrence, p_utilisateur, v_quand);
    RETURN v_occurrence;
END $$;

COMMENT ON FUNCTION declarer_faite IS
    'Valide une tâche faite spontanément, même prévue pour quelqu''un d''autre.
     Reprend l''occurrence ouverte la plus proche, en crée une sinon, et la
     récurrence repart de la date déclarée (EXE-11, EXE-15).';

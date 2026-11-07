-- -----------------------------------------------------------------------------
-- Déclarer faite une tâche qui n'existait pas                          (EXE-17)
--
-- « J'ai détartré la bouilloire » : la tâche est créée ponctuelle (revient =
-- 'dates', TAC-1), avec les valeurs de son type (TAC-25), puis arrêtée à la
-- date dite : elle reste dans l'historique (Tâches arrêtées, TAC-30) et ne
-- revient jamais au planning. Son occurrence est créée puis validée par
-- valider_occurrence, comme declarer_faite : elle est faite à la date dite, au
-- nom de celui qui déclare, et compte comme n'importe quelle tâche faite dans
-- l'équilibre de la semaine.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION declarer_faite_en_plus(
    p_utilisateur   INTEGER,
    p_libelle       TEXT,
    p_type          INTEGER     DEFAULT NULL,
    p_duree_minutes INTEGER     DEFAULT NULL,
    p_quand         TIMESTAMPTZ DEFAULT NULL
) RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE
    v_libelle    TEXT := btrim(regexp_replace(COALESCE(p_libelle, ''), '\s+', ' ', 'g'));
    v_quand      TIMESTAMPTZ := COALESCE(p_quand, now());
    v_type       type_tache%ROWTYPE;
    v_duree      INTEGER;
    v_tache      INTEGER;
    v_occurrence INTEGER;
BEGIN
    IF length(v_libelle) < 2 OR length(v_libelle) > 100 THEN
        RAISE EXCEPTION 'Le nom d''une tâche fait de 2 à 100 caractères'
              USING ERRCODE = 'check_violation';
    END IF;

    IF v_quand > now() THEN
        RAISE EXCEPTION 'On ne déclare pas fait ce qui ne l''est pas encore'
              USING ERRCODE = 'check_violation';
    END IF;

    -- TAC-25 : sans type, le type de base Ménage (comme creer_tache).
    SELECT * INTO v_type FROM type_tache
     WHERE id_type_tache = p_type
        OR (p_type IS NULL AND base = 'menage')
     LIMIT 1;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Ce type de tâche n''existe pas'
              USING ERRCODE = 'check_violation';
    END IF;

    v_duree := COALESCE(p_duree_minutes, v_type.duree_minutes);
    IF v_duree < 1 OR v_duree > 480 THEN
        RAISE EXCEPTION 'La durée va de 1 minute à 8 heures'
              USING ERRCODE = 'check_violation';
    END IF;

    -- Active = FALSE exige arretee_le (contrainte tache_arret_date).
    INSERT INTO tache (libelle, priorite, duree_minutes, revient, ajoutee_par,
                       id_type_tache, si_pas_faite, active, arretee_le)
    VALUES (v_libelle, v_type.priorite, v_duree, 'dates', p_utilisateur,
            v_type.id_type_tache, 'reporter', FALSE, v_quand)
    RETURNING id_tache INTO v_tache;

    -- La fenêtre est la journée dite, comme celle d'une tâche d'un jour.
    INSERT INTO occurrence (id_tache, id_utilisateur, fenetre, statut, origine, motif)
    VALUES (v_tache, p_utilisateur, fenetre_pour(TRUE, v_quand, v_quand),
            'a_placer', 'manuelle', 'Déclarée faite en plus')
    RETURNING id_occurrence INTO v_occurrence;

    PERFORM valider_occurrence(v_occurrence, p_utilisateur, v_quand);
    RETURN v_occurrence;
END $$;

COMMENT ON FUNCTION declarer_faite_en_plus(INTEGER, TEXT, INTEGER, INTEGER, TIMESTAMPTZ) IS
    'EXE-17 : crée une tâche ponctuelle faite en plus (libellé, type, durée du type par défaut), la range parmi les tâches arrêtées, et la valide à la date dite (jamais dans le futur), au nom de celui qui déclare. Rend le numéro de l''occurrence.';

-- -----------------------------------------------------------------------------
-- Reprendre une tâche arrêtée                                          (TAC-30)
--
-- Elle revient telle qu'elle était : ses réglages, ses liens, sa description.
-- Régulière, elle est due dès aujourd'hui, comme une tâche neuve ; ponctuelle,
-- elle retrouve ses dates, si la dernière n'est pas passée ; née d'une autre,
-- elle attend la prochaine fois que l'autre est faite ; selon sa description,
-- HAL la repose.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION reprendre_tache(p_tache INTEGER) RETURNS VOID
LANGUAGE plpgsql AS $$
DECLARE
    t         tache%ROWTYPE;
    v_fenetre TSTZRANGE;
BEGIN
    SELECT * INTO t FROM tache WHERE id_tache = p_tache AND id_type_tache IS NOT NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Tâche % inconnue', p_tache USING ERRCODE = 'no_data_found';
    END IF;
    IF t.active THEN
        RAISE EXCEPTION '« % » n''est pas arrêtée', t.libelle USING ERRCODE = 'check_violation';
    END IF;

    IF t.revient = 'dates' THEN
        SELECT o.fenetre INTO v_fenetre FROM occurrence o
         WHERE o.id_tache = p_tache
         ORDER BY upper(o.fenetre) DESC, o.id_occurrence DESC LIMIT 1;
        IF v_fenetre IS NULL OR upper(v_fenetre) <= now() THEN
            RAISE EXCEPTION '« % » avait une date, maintenant passée : crée-en une autre', t.libelle
                  USING ERRCODE = 'check_violation';
        END IF;
    END IF;

    UPDATE tache SET active = TRUE, arretee_le = NULL WHERE id_tache = p_tache;

    IF t.revient = 'rythme' THEN
        INSERT INTO occurrence (id_tache, fenetre, origine, motif)
        VALUES (p_tache,
                fenetre_pour(t.rappel_journee, now(),
                             date_add(now(), make_interval(days => t.periodicite_max_jours),
                                      'Europe/Paris')),
                'recurrence', 'Reprise');
    ELSIF t.revient = 'dates' THEN
        INSERT INTO occurrence (id_tache, id_utilisateur, fenetre, origine, motif)
        VALUES (p_tache, t.id_utilisateur_defaut,
                tstzrange(GREATEST(lower(v_fenetre), debut_jour(jour_de(now()))),
                          upper(v_fenetre), '[)'),
                'manuelle', 'Reprise');
    ELSIF t.revient = 'description' THEN
        PERFORM noter_verification(NULL, p_tache, 'description');
    END IF;
END $$;

COMMENT ON FUNCTION reprendre_tache(INTEGER) IS
    'TAC-30 : remet au planning une tâche arrêtée, avec ses réglages, ses liens et sa description.';

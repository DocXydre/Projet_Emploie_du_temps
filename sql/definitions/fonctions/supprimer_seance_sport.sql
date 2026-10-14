CREATE OR REPLACE FUNCTION supprimer_seance_sport(
    p_utilisateur INTEGER,
    p_occurrence  INTEGER
) RETURNS DATE LANGUAGE plpgsql AS $$
DECLARE
    v_jour DATE;
BEGIN
    -- Une séance supprimée n'a jamais eu lieu : elle ne laisse pas de trace.
    DELETE FROM occurrence o
     USING tache t
     WHERE t.id_tache = o.id_tache
       AND t.categorie = 'sport'
       AND o.id_occurrence = p_occurrence
       AND o.id_utilisateur = p_utilisateur
       AND o.statut IN ('planifiee', 'notifiee')
    RETURNING jour_de(COALESCE(o.debut_seance, lower(o.creneau))) INTO v_jour;

    IF v_jour IS NULL THEN
        RAISE EXCEPTION 'Séance introuvable, ou déjà passée'
              USING ERRCODE = 'no_data_found';
    END IF;

    RETURN v_jour;
END $$;

COMMENT ON FUNCTION supprimer_seance_sport(INTEGER, INTEGER) IS
    'Supprime une séance à venir : elle n''a jamais eu lieu et ne compte pas
     comme manquée.';

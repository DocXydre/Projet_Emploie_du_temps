-- SPT-25, SPT-36 : « pas faite » n'est pas « supprimée ». La séance est close,
-- et la semaine ne se recomplète pas d'elle-même : HAL en décide (PLN-10).
CREATE OR REPLACE FUNCTION seance_sport_pas_faite(
    p_utilisateur INTEGER,
    p_occurrence  INTEGER
) RETURNS DATE LANGUAGE plpgsql AS $$
DECLARE
    v_jour DATE;
BEGIN
    UPDATE occurrence o
       SET statut = 'abandonnee', motif = 'Pas faite'
      FROM tache t
     WHERE t.id_tache = o.id_tache
       AND t.categorie = 'sport'
       AND o.id_occurrence = p_occurrence
       AND o.id_utilisateur = p_utilisateur
       AND o.statut IN ('planifiee', 'notifiee')
    RETURNING jour_de(COALESCE(o.debut_seance, lower(o.creneau))) INTO v_jour;

    IF v_jour IS NULL THEN
        RAISE EXCEPTION 'Séance introuvable, ou déjà close'
              USING ERRCODE = 'no_data_found';
    END IF;

    RETURN v_jour;
END $$;

COMMENT ON FUNCTION seance_sport_pas_faite(INTEGER, INTEGER) IS
    'SPT-36 : la séance est close comme pas faite ; rien ne la remplace d''office.';

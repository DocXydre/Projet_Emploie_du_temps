-- SPT-25 : « pas faite » n'est pas « supprimée ». La séance a été choisie, le
-- choix compte pour les habitudes ; elle est close, et la semaine se complète.
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

    PERFORM organiser_sport_semaine(p_utilisateur, lundi_de(v_jour));
    RETURN v_jour;
END $$;

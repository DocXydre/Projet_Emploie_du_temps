CREATE OR REPLACE FUNCTION supprimer_seance_sport(
    p_utilisateur INTEGER,
    p_occurrence  INTEGER
) RETURNS DATE LANGUAGE plpgsql AS $$
DECLARE
    v_jour DATE;
BEGIN
    -- Une séance supprimée n'a jamais eu lieu : elle ne laisse pas de trace, et
    -- son choix part avec elle (ON DELETE CASCADE).
    DELETE FROM occurrence o
     USING tache t
     WHERE t.id_tache = o.id_tache
       AND t.categorie = 'sport'
       AND o.id_occurrence = p_occurrence
       AND o.id_utilisateur = p_utilisateur
       AND o.origine <> 'quota'
       AND o.statut IN ('planifiee', 'notifiee')
    RETURNING jour_de(COALESCE(o.debut_seance, lower(o.creneau))) INTO v_jour;

    IF v_jour IS NULL THEN
        RAISE EXCEPTION 'Séance introuvable, ou déjà passée'
              USING ERRCODE = 'no_data_found';
    END IF;

    PERFORM organiser_sport_semaine(p_utilisateur, lundi_de(v_jour));
    -- Le choix effacé ne compte plus pour les habitudes : les autres semaines
    -- se refont sans lui.
    PERFORM organiser_sport_semaine(p_utilisateur, lundi_de(jour_de(now())) + 7 * i, TRUE)
       FROM generate_series(0, 2) i
      WHERE lundi_de(jour_de(now())) + 7 * i <> lundi_de(v_jour);
    RETURN v_jour;
END $$;

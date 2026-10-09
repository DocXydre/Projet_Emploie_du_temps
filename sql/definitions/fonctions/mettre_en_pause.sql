-- -----------------------------------------------------------------------------
-- L'utilisateur met son coach en pause                    (opération C15)
--                                                    (PAU-1, PAU-2, PAU-7)
--
-- Les séances proposées de la période sont retirées. Les séances validées sont
-- signalées : c'est l'utilisateur qui les garde ou les supprime. Une pause
-- n'est pas une absence : elle dit qu'on ne suit pas le plan, pas où l'on est.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION mettre_en_pause(p_utilisateur INTEGER,
                                           p_fin DATE DEFAULT NULL,
                                           p_motif TEXT DEFAULT NULL)
RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE
    v_jour    DATE := jour_de(now());
    v_periode DATERANGE;
    v_pause   INTEGER;
    v_gardees INTEGER;
BEGIN
    PERFORM exiger_coach(p_utilisateur);

    IF en_pause(p_utilisateur) THEN
        PERFORM refus_coach('coach_en_pause', 'Le coach est déjà en pause');
    END IF;
    IF p_fin IS NOT NULL AND p_fin < v_jour THEN
        PERFORM refus_coach('requete_invalide', 'La fin de la pause est déjà passée');
    END IF;

    v_periode := daterange(v_jour, p_fin + 1, '[)');
    INSERT INTO pause (id_utilisateur, periode, motif)
    VALUES (p_utilisateur, v_periode, NULLIF(btrim(p_motif), ''))
    RETURNING id_pause INTO v_pause;

    DELETE FROM occurrence o
     USING seance se
     WHERE se.id_occurrence = o.id_occurrence
       AND o.id_utilisateur = p_utilisateur
       AND se.auteur = 'coach' AND se.etat = 'proposee'
       AND o.statut IN ('planifiee', 'notifiee')
       AND o.debut_seance > now()
       AND v_periode @> jour_de(o.debut_seance);

    UPDATE ajustement a SET statut = 'caduc'
      FROM occurrence o
     WHERE o.id_occurrence = a.id_occurrence
       AND o.id_utilisateur = p_utilisateur
       AND a.statut = 'propose'
       AND v_periode @> jour_de(o.debut_seance);

    SELECT count(*) INTO v_gardees
      FROM occurrence o JOIN seance se ON se.id_occurrence = o.id_occurrence
     WHERE o.id_utilisateur = p_utilisateur
       AND se.auteur = 'coach' AND se.etat = 'validee'
       AND o.statut IN ('planifiee', 'notifiee')
       AND v_periode @> jour_de(o.debut_seance);
    IF v_gardees > 0 THEN
        INSERT INTO notification (id_utilisateur, type, contenu)
        VALUES (p_utilisateur, 'coach',
                format('Coach en pause. %s séance(s) validée(s) restent au planning '
                       || 'pendant la pause : à toi de les garder ou de les supprimer.',
                       v_gardees));
    END IF;
    RETURN v_pause;
END $$;

COMMENT ON FUNCTION mettre_en_pause(INTEGER, DATE, TEXT) IS
    'Opération C15 : met le coach en pause, avec ou sans date de fin. Retire
     les séances proposées de la période et signale les validées (PAU-1, PAU-2).';

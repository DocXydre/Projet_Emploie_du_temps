-- -----------------------------------------------------------------------------
-- Ajouter une tâche, une fois ou régulière                             (TAC-20)
--
-- Deux formes, et l'une exclut l'autre. Régulière : tous les N jours, avec un
-- peu de jeu pour que le placement ait le choix du jour. Ponctuelle : à faire
-- une fois, avant une date.
--
-- Une tâche ponctuelle ne s'abandonne pas toute seule. Les tâches de ménage
-- reviennent d'elles-mêmes, on peut en laisser passer une ; un colis à rendre
-- ne reviendra pas, il reste en retard jusqu'à ce qu'on le fasse ou qu'on le
-- refuse.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ajouter_tache(p_libelle        TEXT,
                                         p_acteur         INTEGER,
                                         p_tous_les_jours INTEGER DEFAULT NULL,
                                         p_echeance       DATE    DEFAULT NULL,
                                         p_pour           INTEGER DEFAULT NULL,
                                         p_duree_minutes  INTEGER DEFAULT 15)
RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE
    v_libelle TEXT := btrim(regexp_replace(COALESCE(p_libelle, ''), '\s+', ' ', 'g'));
    v_tache   INTEGER;
BEGIN
    IF length(v_libelle) < 2 OR length(v_libelle) > 100 THEN
        RAISE EXCEPTION 'Le nom d''une tâche fait de 2 à 100 caractères'
              USING ERRCODE = 'check_violation';
    END IF;
    IF (p_tous_les_jours IS NULL) = (p_echeance IS NULL) THEN
        RAISE EXCEPTION 'Une tâche est régulière ou ponctuelle : donne un rythme ou une date, pas les deux'
              USING ERRCODE = 'check_violation';
    END IF;
    IF p_tous_les_jours IS NOT NULL AND (p_tous_les_jours < 1 OR p_tous_les_jours > 730) THEN
        RAISE EXCEPTION 'Le rythme va de 1 à 730 jours'
              USING ERRCODE = 'check_violation';
    END IF;
    IF p_echeance IS NOT NULL AND p_echeance < jour_de(now()) THEN
        RAISE EXCEPTION 'La date est déjà passée'
              USING ERRCODE = 'check_violation';
    END IF;
    IF p_duree_minutes IS NULL OR p_duree_minutes < 1 OR p_duree_minutes > 480 THEN
        RAISE EXCEPTION 'La durée va de 1 minute à 8 heures'
              USING ERRCODE = 'check_violation';
    END IF;

    INSERT INTO tache (code, libelle, categorie, priorite, duree_minutes,
                       periodicite_min_jours, periodicite_max_jours,
                       rappel_journee, reportable, recurrente,
                       id_utilisateur_defaut, abandon_apres_jours, ajoutee_par)
    VALUES ('AJOUT_' || nextval(pg_get_serial_sequence('tache', 'id_tache')),
            v_libelle,
            'menage',
            -- PLA-14 : une échéance passe avant le ménage courant, un cycle
            -- long après lui.
            CASE WHEN p_echeance IS NOT NULL THEN 2
                 WHEN p_tous_les_jours >= 28 THEN 5
                 ELSE 4 END,
            p_duree_minutes,
            COALESCE(p_tous_les_jours, 1),
            -- Un septième de jeu : un jour pour une tâche hebdomadaire, deux
            -- semaines pour une tâche trimestrielle.
            COALESCE(p_tous_les_jours + GREATEST(1, p_tous_les_jours / 7), 1),
            TRUE, TRUE,
            p_tous_les_jours IS NOT NULL,
            p_pour,
            CASE WHEN p_echeance IS NOT NULL THEN 0 ELSE 5 END,
            p_acteur)
    RETURNING id_tache INTO v_tache;

    IF p_echeance IS NOT NULL THEN
        INSERT INTO occurrence (id_tache, id_utilisateur, fenetre, origine, motif)
        VALUES (v_tache, p_pour,
                tstzrange(debut_jour(jour_de(now())), debut_jour(p_echeance + 1), '[)'),
                'manuelle',
                format('À faire avant le %s', to_char(p_echeance, 'DD/MM')));
    END IF;

    RETURN v_tache;
END $$;

COMMENT ON FUNCTION ajouter_tache(TEXT, INTEGER, INTEGER, DATE, INTEGER, INTEGER) IS
    'TAC-20 : crée une tâche régulière (tous les N jours) ou ponctuelle (avant
     une date), pour quelqu''un ou à tour de rôle. Le placement suivant la pose.';

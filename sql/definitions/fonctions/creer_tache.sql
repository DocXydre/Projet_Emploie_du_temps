-- -----------------------------------------------------------------------------
-- Créer une tâche, de l'appli                               (TAC-20 à TAC-24)
--
-- Une tâche revient d'une seule des quatre façons (TAC-1) :
--
--   régulière          tous les N jours, avec un septième de jeu
--   une fois           du … au … : pas avant le premier jour, au plus tard le
--                      second. Aujourd'hui, c'est du jour au jour même
--   après une autre    sans rythme propre : elle naît d'un lien « Ensuite »,
--                      comme vider le lave-vaisselle (TAC-8, TAC-27)
--   selon sa description  sans rythme ni dates : HAL en pose les occurrences
--                      (MTA-8). Seul HAL la crée ainsi, l'appli ne l'offre pas
--
-- Et elle a l'une de trois heures : sans heure (un rappel dans la journée),
-- « à 18h30 » (une plage de la longueur exacte de la tâche), ou « entre 18h
-- et 21h ». Le type donne la famille, la durée et la priorité par défaut.
--
-- C'est la seule fonction qui crée une tâche de la maison (TAC-20) : la route,
-- l'appli et HAL l'appellent. Toute tâche dit ce qu'elle devient si elle n'est
-- pas faite à temps : reportée, ou oubliée (TAC-24).
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION creer_tache(p_libelle          TEXT,
                                       p_acteur           INTEGER,
                                       p_type             INTEGER DEFAULT NULL,
                                       p_duree_minutes    INTEGER DEFAULT NULL,
                                       p_pour             INTEGER DEFAULT NULL,
                                       p_tous_les_jours   INTEGER DEFAULT NULL,
                                       p_du               DATE    DEFAULT NULL,
                                       p_au               DATE    DEFAULT NULL,
                                       p_apres            INTEGER DEFAULT NULL,
                                       p_delai_min_heures INTEGER DEFAULT NULL,
                                       p_delai_max_heures INTEGER DEFAULT NULL,
                                       p_heure_min        TIME    DEFAULT NULL,
                                       p_heure_max        TIME    DEFAULT NULL,
                                       p_si_pas_faite     TEXT    DEFAULT 'reporter',
                                       p_priorite         INTEGER DEFAULT NULL,
                                       p_selon_description BOOLEAN DEFAULT FALSE)
RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE
    v_libelle    TEXT := btrim(regexp_replace(COALESCE(p_libelle, ''), '\s+', ' ', 'g'));
    v_aujourdhui DATE := jour_de(now());
    v_ponctuelle BOOLEAN := p_du IS NOT NULL OR p_au IS NOT NULL;
    v_du         DATE;
    v_au         DATE;
    v_type       type_tache%ROWTYPE;
    v_duree      INTEGER;
    v_tache      INTEGER;
BEGIN
    IF length(v_libelle) < 2 OR length(v_libelle) > 100 THEN
        RAISE EXCEPTION 'Le nom d''une tâche fait de 2 à 100 caractères'
              USING ERRCODE = 'check_violation';
    END IF;

    IF (p_tous_les_jours IS NOT NULL)::INTEGER + v_ponctuelle::INTEGER
       + (p_apres IS NOT NULL)::INTEGER + COALESCE(p_selon_description, FALSE)::INTEGER <> 1 THEN
        RAISE EXCEPTION 'Une tâche revient d''une seule façon : un rythme, des dates, après une autre tâche, ou selon sa description'
              USING ERRCODE = 'check_violation';
    END IF;
    IF p_tous_les_jours IS NOT NULL AND (p_tous_les_jours < 1 OR p_tous_les_jours > 730) THEN
        RAISE EXCEPTION 'Le rythme va de 1 à 730 jours'
              USING ERRCODE = 'check_violation';
    END IF;

    -- TAC-22 : sans premier jour, c'est à partir d'aujourd'hui ; sans second,
    -- c'est le jour même.
    IF v_ponctuelle THEN
        v_du := COALESCE(p_du, v_aujourdhui);
        v_au := COALESCE(p_au, v_du);
        IF v_du < v_aujourdhui OR v_au < v_aujourdhui THEN
            RAISE EXCEPTION 'La date est déjà passée'
                  USING ERRCODE = 'check_violation';
        END IF;
        IF v_au < v_du THEN
            RAISE EXCEPTION 'La date de fin précède celle du début'
                  USING ERRCODE = 'check_violation';
        END IF;
    END IF;

    -- TAC-25 : sans type, le type de base Ménage.
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

    PERFORM verifier_plage_horaire(p_heure_min, p_heure_max, v_duree);

    IF COALESCE(p_si_pas_faite, 'reporter') NOT IN ('reporter', 'oublier') THEN
        RAISE EXCEPTION 'Une tâche pas faite se reporte ou s''oublie'
              USING ERRCODE = 'check_violation';
    END IF;

    IF p_apres IS NOT NULL AND NOT EXISTS (
           SELECT 1 FROM tache WHERE id_tache = p_apres AND active AND id_type_tache IS NOT NULL) THEN
        RAISE EXCEPTION 'La tâche après laquelle venir n''existe pas, ou elle est arrêtée'
              USING ERRCODE = 'check_violation';
    END IF;

    INSERT INTO tache (libelle, priorite, duree_minutes, revient,
                       periodicite_min_jours, periodicite_max_jours,
                       heure_min, heure_max, id_utilisateur_defaut,
                       ajoutee_par, id_type_tache, si_pas_faite)
    VALUES (v_libelle,
            COALESCE(p_priorite, v_type.priorite),
            v_duree,
            CASE WHEN p_tous_les_jours IS NOT NULL THEN 'rythme'
                 WHEN v_ponctuelle THEN 'dates'
                 WHEN p_apres IS NOT NULL THEN 'apres'
                 ELSE 'description' END,
            p_tous_les_jours,
            -- Un septième de jeu : un jour pour une tâche hebdomadaire, deux
            -- semaines pour une tâche trimestrielle.
            p_tous_les_jours + GREATEST(1, p_tous_les_jours / 7),
            p_heure_min, p_heure_max,
            p_pour,
            p_acteur,
            v_type.id_type_tache,
            COALESCE(p_si_pas_faite, 'reporter'))
    RETURNING id_tache INTO v_tache;

    IF v_ponctuelle THEN
        INSERT INTO occurrence (id_tache, id_utilisateur, fenetre, origine, motif)
        VALUES (v_tache, p_pour,
                tstzrange(debut_jour(v_du), debut_jour(v_au + 1), '[)'),
                'manuelle',
                CASE WHEN v_du = v_au AND v_du = v_aujourdhui THEN 'À faire aujourd''hui'
                     WHEN v_du = v_au THEN format('À faire le %s', to_char(v_du, 'DD/MM'))
                     WHEN v_du = v_aujourdhui THEN format('À faire avant le %s', to_char(v_au, 'DD/MM'))
                     ELSE format('À faire du %s au %s', to_char(v_du, 'DD/MM'), to_char(v_au, 'DD/MM'))
                END);
    END IF;

    -- TAC-27 : « après une autre » est un lien « Ensuite » vers elle.
    IF p_apres IS NOT NULL THEN
        PERFORM lier_taches('ensuite', p_apres, v_tache,
                            COALESCE(p_delai_min_heures, 0),
                            COALESCE(p_delai_max_heures, 24));
    END IF;

    RETURN v_tache;
END $$;

COMMENT ON FUNCTION creer_tache(TEXT, INTEGER, INTEGER, INTEGER, INTEGER, INTEGER, DATE, DATE,
                                INTEGER, INTEGER, INTEGER, TIME, TIME, TEXT, INTEGER, BOOLEAN) IS
    'TAC-20 à TAC-24, MTA-8 : crée une tâche régulière, ponctuelle (du … au …),
     née d''une autre ou selon sa description, sans heure, à une heure ou dans
     une plage. Rend son numéro.';

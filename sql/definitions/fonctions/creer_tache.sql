-- -----------------------------------------------------------------------------
-- Créer une tâche, de l'appli                               (TAC-20 à TAC-24)
--
-- Une tâche revient d'une seule des trois façons :
--
--   régulière          tous les N jours, avec un septième de jeu ; ou N fois
--                      par semaine ou par mois (CND-4)
--   une fois           du … au … : pas avant le premier jour, au plus tard le
--                      second. Aujourd'hui, c'est du jour au jour même
--   après une autre    sans rythme propre : elle naît d'un lien « Ensuite »,
--                      comme vider le lave-vaisselle (TAC-8, TAC-27)
--
-- Et elle a l'une de trois heures : sans heure (un rappel dans la journée),
-- « à 18h30 » (une plage de la longueur exacte de la tâche), ou « entre 18h
-- et 21h ». Le type donne la famille, la durée et la priorité par défaut.
--
-- Une tâche ponctuelle ne s'abandonne pas au nom du retard (EXE-12) ; elle
-- peut en revanche demander à être oubliée si sa dernière date passe (TAC-24).
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
                                       p_fois             INTEGER DEFAULT NULL,
                                       p_par              TEXT    DEFAULT NULL,
                                       p_moment           TEXT    DEFAULT 'indifferent')
RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE
    v_libelle    TEXT := btrim(regexp_replace(COALESCE(p_libelle, ''), '\s+', ' ', 'g'));
    v_aujourdhui DATE := jour_de(now());
    v_ponctuelle BOOLEAN := p_du IS NOT NULL OR p_au IS NOT NULL;
    v_reguliere  BOOLEAN := p_tous_les_jours IS NOT NULL OR p_fois IS NOT NULL;
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

    IF v_reguliere::INTEGER + v_ponctuelle::INTEGER
       + (p_apres IS NOT NULL)::INTEGER <> 1
       OR (p_tous_les_jours IS NOT NULL AND p_fois IS NOT NULL) THEN
        RAISE EXCEPTION 'Une tâche revient d''une seule façon : un rythme, des dates, ou après une autre tâche'
              USING ERRCODE = 'check_violation';
    END IF;
    IF p_tous_les_jours IS NOT NULL AND (p_tous_les_jours < 1 OR p_tous_les_jours > 730) THEN
        RAISE EXCEPTION 'Le rythme va de 1 à 730 jours'
              USING ERRCODE = 'check_violation';
    END IF;
    -- CND-4 : N fois par semaine ou par mois.
    IF p_fois IS NOT NULL AND (COALESCE(p_par, '') NOT IN ('semaine', 'mois')
                               OR p_fois NOT BETWEEN 1 AND (CASE p_par WHEN 'semaine' THEN 7 ELSE 31 END)) THEN
        RAISE EXCEPTION 'De 1 à 7 fois par semaine, ou de 1 à 31 fois par mois'
              USING ERRCODE = 'check_violation';
    END IF;
    IF COALESCE(p_moment, 'indifferent') NOT IN ('debut', 'milieu', 'fin', 'indifferent') THEN
        RAISE EXCEPTION 'Le moment préféré : début, milieu, fin, ou indifférent'
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

    -- TAC-25 : sans type, le premier type de ménage.
    SELECT * INTO v_type FROM type_tache
     WHERE id_type_tache = p_type
        OR (p_type IS NULL AND categorie = 'menage')
     ORDER BY ordre, id_type_tache
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
           SELECT 1 FROM tache WHERE id_tache = p_apres AND active AND categorie <> 'sport') THEN
        RAISE EXCEPTION 'La tâche après laquelle venir n''existe pas, ou elle est arrêtée'
              USING ERRCODE = 'check_violation';
    END IF;

    INSERT INTO tache (code, libelle, categorie, priorite, duree_minutes,
                       periodicite_min_jours, periodicite_max_jours,
                       rappel_journee, heure_min, heure_max,
                       reportable, recurrente, id_utilisateur_defaut,
                       abandon_apres_jours, ajoutee_par, id_type_tache, si_pas_faite,
                       rythme_nombre, rythme_periode, rythme_moment)
    VALUES ('AJOUT_' || nextval(pg_get_serial_sequence('tache', 'id_tache')),
            v_libelle,
            v_type.categorie,
            COALESCE(p_priorite, v_type.priorite),
            v_duree,
            COALESCE(p_tous_les_jours, 1),
            -- Un septième de jeu : un jour pour une tâche hebdomadaire, deux
            -- semaines pour une tâche trimestrielle.
            COALESCE(p_tous_les_jours + GREATEST(1, p_tous_les_jours / 7), 1),
            p_heure_min IS NULL, p_heure_min, p_heure_max,
            TRUE,
            v_reguliere,
            p_pour,
            CASE WHEN v_ponctuelle THEN 0 ELSE 5 END,
            p_acteur,
            v_type.id_type_tache,
            CASE WHEN v_ponctuelle THEN COALESCE(p_si_pas_faite, 'reporter') ELSE 'reporter' END,
            -- La périodicité qui va avec le rythme, le déclencheur la calcule.
            p_fois, CASE WHEN p_fois IS NOT NULL THEN p_par END,
            COALESCE(p_moment, 'indifferent'))
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
                                INTEGER, INTEGER, INTEGER, TIME, TIME, TEXT, INTEGER,
                                INTEGER, TEXT, TEXT) IS
    'TAC-20 à TAC-24, CND-4 : crée une tâche régulière (tous les N jours, ou N fois
     par semaine ou par mois), ponctuelle (du … au …) ou née d''une autre, sans
     heure, à une heure ou dans une plage. Rend son numéro.';

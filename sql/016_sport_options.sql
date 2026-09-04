-- rejouable : ALTER ... IF NOT EXISTS, INSERT idempotents, CREATE OR REPLACE.
-- =============================================================================
-- 016 : trois façons de faire du sport                       (SPT-9 à SPT-13)
--
-- Après une semaine d'usage, trois choses manquaient.
--
-- La salle tombait à 21h les jours vides. « Le plus tard possible dans le
-- creux » donne le bon résultat un jour de cours — la séance suit l'amphi — et
-- le mauvais un jour sans : le creux fait quinze heures, et sa fin est le soir.
--
-- Une séance ne réservait que son trajet. Rien ne garantissait un moment de
-- battement avant et après, alors que c'est ce qui rend la séance faisable.
--
-- Enfin les trois séances de la semaine étaient posées d'office, sans qu'on
-- puisse arbitrer entre piscine, course et salle.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- Ce qui change selon le lieu                                    (SPT-9, SPT-10)
-- -----------------------------------------------------------------------------

-- SPT-9 : la durée dépend du lieu, pas de la tâche. Une heure de piscine, une
-- demi-heure de course. NULL = on garde la durée de la tâche.
ALTER TABLE lieu_sport
    ADD COLUMN IF NOT EXISTS duree_minutes SMALLINT
        CHECK (duree_minutes IS NULL OR duree_minutes > 0);

-- SPT-10 : du vide de part et d'autre, en plus du trajet. Enchaîner un cours et
-- une séance à la minute près ne se fait pas dans la vraie vie.
ALTER TABLE lieu_sport
    ADD COLUMN IF NOT EXISTS marge_minutes SMALLINT NOT NULL DEFAULT 30
        CHECK (marge_minutes >= 0);

-- SPT-11 : l'heure à laquelle commencer une journée sans obligation. Sans elle,
-- un lieu ouvert toute la journée voyait sa séance repoussée au soir.
ALTER TABLE lieu_sport
    ADD COLUMN IF NOT EXISTS heure_defaut TIME NOT NULL DEFAULT '10:00';

COMMENT ON COLUMN lieu_sport.duree_minutes IS
    'Durée propre au lieu, trajet exclu. NULL : celle de la tâche (SPT-9).';

COMMENT ON COLUMN lieu_sport.marge_minutes IS
    'Battement libre exigé avant et après la séance, en plus du trajet (SPT-10).';

COMMENT ON COLUMN lieu_sport.heure_defaut IS
    'Heure de départ un jour sans aucune obligation (SPT-11).';


-- SPT-12 : « après » remplace « tard » pour la salle. On ne veut pas la fin du
-- creux, on veut la suite des cours.
ALTER TABLE lieu_sport DROP CONSTRAINT IF EXISTS lieu_sport_preference_check;
ALTER TABLE lieu_sport ADD CONSTRAINT lieu_sport_preference_check
    CHECK (preference IN ('tot', 'tard', 'apres'));

COMMENT ON COLUMN lieu_sport.preference IS
    'tot   : au plus tôt dans le creux, pour un lieu à créneaux courts.
     apres : juste après la dernière obligation du jour, ou à heure_defaut si
             la journée est vide (SPT-12).
     tard  : au plus tard dans le creux. Conservé, plus utilisé.';


-- -----------------------------------------------------------------------------
-- La course à pied                                                       (SPT-9)
--
-- Elle part du pas de la porte : aucun trajet, et une marge plus courte, une
-- demi-heure de course ne demandant pas la même préparation qu'une piscine.
-- -----------------------------------------------------------------------------
INSERT INTO lieu_sport (code, libelle, minutes_domicile, minutes_fac,
                        heure_min, heure_max, heure_tardive, repos_heures,
                        preference, duree_minutes, marge_minutes, heure_defaut)
VALUES ('COURSE', 'Course à pied', 0, 0, '07:00', '21:00', NULL, 0,
        'apres', 30, 15, '10:00')
ON CONFLICT (code) DO NOTHING;

-- Troisième possibilité pour la même séance hebdomadaire : ce n'est pas une
-- quatrième séance, c'est une autre manière de faire l'une des trois.
INSERT INTO tache_lieu (id_tache, id_lieu, rang)
SELECT t.id_tache, l.id_lieu, 3
  FROM tache t, lieu_sport l
 WHERE t.code = 'SPORT' AND l.code = 'COURSE'
ON CONFLICT (id_tache, id_lieu) DO NOTHING;

-- La salle suit désormais les cours au lieu de fermer la journée.
UPDATE lieu_sport
   SET preference = 'apres', marge_minutes = 30, heure_defaut = '10:00'
 WHERE code = 'SALLE';

UPDATE lieu_sport
   SET marge_minutes = 30, heure_defaut = '10:00'
 WHERE code = 'PISCINE_SUAPS';


-- -----------------------------------------------------------------------------
-- Fin de la dernière obligation d'une journée                           (SPT-12)
--
-- NULL quand la journée est vide : c'est le cas que `heure_defaut` traite.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fin_des_obligations(p_utilisateur INTEGER, p_jour DATE)
RETURNS TIMESTAMPTZ LANGUAGE sql STABLE AS $$
    SELECT max(LEAST(upper(o.periode), debut_jour(p_jour + 1)))
      FROM occupation o
     WHERE o.id_utilisateur = p_utilisateur
       AND o.type IN ('cours', 'travail')
       AND o.periode && tstzrange(debut_jour(p_jour), debut_jour(p_jour + 1), '[)');
$$;


-- -----------------------------------------------------------------------------
-- Chercher un créneau de sport                                    (SPT-1 à SPT-12)
--
-- Rend le créneau **trajet et marges compris** : c'est ce temps-là qu'il faut
-- réserver pour que la séance tienne debout.
--
--     marge | trajet | séance | trajet | marge
--
-- Le lieu retenu sort par `lieu_retenu`, une même séance pouvant se faire à la
-- piscine, en courant ou à la salle.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION chercher_creneau_sport(
    p_utilisateur   INTEGER,
    p_tache         INTEGER,
    p_fenetre       TSTZRANGE,
    p_duree         INTERVAL,
    OUT creneau     TSTZRANGE,
    OUT lieu_retenu INTEGER
) LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_jour    DATE;
    v_dernier DATE;
BEGIN
    v_jour    := GREATEST(jour_de(lower(p_fenetre)), jour_de(now()));
    v_dernier := jour_de(upper(p_fenetre) - INTERVAL '1 second');

    WHILE v_jour <= v_dernier LOOP
        SELECT c.creneau, c.id_lieu INTO creneau, lieu_retenu
          FROM creneaux_sport_du_jour(p_utilisateur, p_tache, v_jour, p_duree) c
         ORDER BY c.rang, lower(c.creneau)
         LIMIT 1;

        IF creneau IS NOT NULL THEN
            RETURN;
        END IF;

        v_jour := v_jour + 1;
    END LOOP;

    creneau := NULL;
    lieu_retenu := NULL;
END $$;


-- -----------------------------------------------------------------------------
-- Tous les créneaux possibles un jour donné                       (SPT-12, SPT-13)
--
-- Une ligne par lieu praticable ce jour-là, avec son meilleur créneau. C'est ce
-- que le placement consomme (il prend la première ligne) et ce que la
-- proposition du lundi affiche (elle les montre toutes).
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION creneaux_sport_du_jour(
    p_utilisateur INTEGER,
    p_tache       INTEGER,
    p_jour        DATE,
    p_duree       INTERVAL DEFAULT NULL
) RETURNS TABLE (
    id_lieu INTEGER,
    code    VARCHAR,
    libelle VARCHAR,
    rang    SMALLINT,
    creneau TSTZRANGE
) LANGUAGE plpgsql STABLE AS $$
DECLARE
    l        RECORD;
    v_plage  TSTZRANGE;
    v_dispo  TSTZRANGE;
    v_trajet INTERVAL;
    v_marge  INTERVAL;
    v_duree  INTERVAL;
    v_total  INTERVAL;
    v_ancre  TIMESTAMPTZ;
    v_debut  TIMESTAMPTZ;
    v_pris   BOOLEAN;
BEGIN
    -- SPT-6 : une seule séance par jour, et rien un jour d'absence.
    IF est_absent(p_utilisateur, p_jour)
       OR EXISTS (SELECT 1 FROM occurrence o
                    JOIN tache t ON t.id_tache = o.id_tache
                   WHERE o.id_utilisateur = p_utilisateur
                     AND t.categorie = 'sport'
                     AND o.creneau IS NOT NULL
                     AND jour_de(lower(o.creneau)) = p_jour
                     AND o.statut IN ('planifiee', 'notifiee')) THEN
        RETURN;
    END IF;

    FOR l IN SELECT ls.*, tl.rang AS preference_rang
               FROM tache_lieu tl
               JOIN lieu_sport ls ON ls.id_lieu = tl.id_lieu
              WHERE tl.id_tache = p_tache
              ORDER BY tl.rang, ls.id_lieu
    LOOP
        v_trajet := make_interval(
            mins => trajet_minutes(p_utilisateur, p_jour, l.id_lieu));
        v_marge  := make_interval(mins => l.marge_minutes);
        v_duree  := COALESCE(make_interval(mins => l.duree_minutes),
                             p_duree,
                             (SELECT make_interval(mins => duree_minutes)
                                FROM tache WHERE id_tache = p_tache));
        -- SPT-10 : la réservation englobe les marges. Le battement doit être
        -- libre, pas seulement souhaité.
        v_total := v_duree + 2 * v_trajet + 2 * v_marge;

        -- SPT-12 : l'ancre est la fin des cours et du travail. Journée vide,
        -- pas d'ancre : on part à l'heure par défaut plutôt qu'au petit matin
        -- ou en soirée.
        v_ancre := fin_des_obligations(p_utilisateur, p_jour);
        IF v_ancre IS NULL THEN
            v_ancre := (p_jour + l.heure_defaut) AT TIME ZONE 'Europe/Paris';
        END IF;

        v_pris := FALSE;

        FOR v_plage IN SELECT * FROM plages_ouvertes(l.id_lieu, p_jour) LOOP
            EXIT WHEN v_pris;

            -- Trajet et marge débordent de l'ouverture : on peut marcher, et
            -- attendre, avant que la piscine n'ouvre.
            v_plage := tstzrange(lower(v_plage) - v_trajet - v_marge,
                                 upper(v_plage) + v_trajet + v_marge, '[)')
                       * tstzrange(now(), NULL, '[)');
            CONTINUE WHEN isempty(v_plage);

            FOR v_dispo IN
                SELECT d FROM disponibilites(p_utilisateur,
                                             lower(v_plage), upper(v_plage)) d
                 ORDER BY CASE WHEN l.preference = 'tard' THEN lower(d) END DESC,
                          lower(d)
            LOOP
                CONTINUE WHEN upper(v_dispo) - lower(v_dispo) < v_total;

                v_debut := CASE l.preference
                    WHEN 'tard'  THEN upper(v_dispo) - v_total
                    -- On ne remonte jamais avant le début du creux, et on ne
                    -- descend jamais sous l'ancre : le premier moment tenable
                    -- après les cours.
                    WHEN 'apres' THEN GREATEST(lower(v_dispo), v_ancre)
                    ELSE lower(v_dispo)
                END;

                CONTINUE WHEN v_debut + v_total > upper(v_dispo);

                -- SPT-7 : le repos se juge sur la fin de la séance elle-même,
                -- marge et trajet du retour exclus.
                CONTINUE WHEN NOT repos_suffisant(
                    p_utilisateur, l.id_lieu,
                    v_debut + v_marge + v_trajet + v_duree);

                id_lieu := l.id_lieu;
                code    := l.code;
                libelle := l.libelle;
                rang    := l.preference_rang;
                creneau := tstzrange(v_debut, v_debut + v_total, '[)');
                RETURN NEXT;

                v_pris := TRUE;
                EXIT;
            END LOOP;
        END LOOP;
    END LOOP;
END $$;

COMMENT ON FUNCTION creneaux_sport_du_jour IS
    'Meilleur créneau par lieu praticable ce jour-là, marges et trajet compris.
     Une ligne par possibilité, du lieu le plus souhaité au moins souhaité.';


-- -----------------------------------------------------------------------------
-- Ce qu'on peut proposer pour la semaine                                (SPT-13)
--
-- Une ligne par jour et par lieu praticable, sur la semaine demandée. Le bot en
-- fait la proposition du lundi matin.
--
-- Les jours déjà pourvus sont écartés par `creneaux_sport_du_jour`, qui refuse
-- un jour portant déjà une séance placée.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION creneaux_sport_semaine(
    p_utilisateur INTEGER,
    p_lundi       DATE DEFAULT NULL
) RETURNS TABLE (
    jour    DATE,
    id_lieu INTEGER,
    code    VARCHAR,
    libelle VARCHAR,
    rang    SMALLINT,
    creneau TSTZRANGE
) LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_lundi DATE := COALESCE(p_lundi, lundi_de(jour_de(now())));
    v_tache INTEGER;
    d       DATE;
BEGIN
    SELECT id_tache INTO v_tache FROM tache WHERE code = 'SPORT' AND active;
    IF v_tache IS NULL THEN
        RETURN;
    END IF;

    d := GREATEST(v_lundi, jour_de(now()));
    WHILE d < v_lundi + 7 LOOP
        RETURN QUERY
        SELECT d, c.id_lieu, c.code, c.libelle, c.rang, c.creneau
          FROM creneaux_sport_du_jour(p_utilisateur, v_tache, d) c;
        d := d + 1;
    END LOOP;
END $$;


-- -----------------------------------------------------------------------------
-- Combien de séances restent à caser cette semaine                       (SPT-5)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION seances_sport_restantes(
    p_utilisateur INTEGER,
    p_lundi       DATE DEFAULT NULL
) RETURNS INTEGER LANGUAGE sql STABLE AS $$
    SELECT count(*)::INTEGER
      FROM occurrence o
      JOIN tache t ON t.id_tache = o.id_tache
     WHERE o.id_utilisateur = p_utilisateur
       AND t.categorie = 'sport'
       AND lower(o.fenetre) = debut_jour(COALESCE(p_lundi, lundi_de(jour_de(now()))))
       AND o.statut IN ('a_placer', 'planifiee')
       AND (o.creneau IS NULL OR NOT o.epinglee);
$$;


-- -----------------------------------------------------------------------------
-- Retenir une séance                                                    (SPT-13)
--
-- Épingle l'occurrence sur le jour et le lieu choisis, pour que le replacement
-- de la nuit n'y touche plus.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION retenir_seance_sport(
    p_utilisateur INTEGER,
    p_jour        DATE,
    p_lieu        INTEGER
) RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE
    v_tache      INTEGER;
    v_occurrence INTEGER;
    v_creneau    TSTZRANGE;
BEGIN
    SELECT id_tache INTO v_tache FROM tache WHERE code = 'SPORT' AND active;

    SELECT c.creneau INTO v_creneau
      FROM creneaux_sport_du_jour(p_utilisateur, v_tache, p_jour) c
     WHERE c.id_lieu = p_lieu;

    IF v_creneau IS NULL THEN
        RAISE EXCEPTION 'Plus de créneau possible ce jour-là dans ce lieu'
              USING ERRCODE = 'check_violation';
    END IF;

    -- La séance non encore posée de la semaine du jour choisi.
    SELECT o.id_occurrence INTO v_occurrence
      FROM occurrence o
     WHERE o.id_tache = v_tache
       AND o.id_utilisateur = p_utilisateur
       AND lower(o.fenetre) = debut_jour(lundi_de(p_jour))
       AND o.statut IN ('a_placer', 'planifiee')
       AND NOT o.epinglee
     ORDER BY o.creneau NULLS FIRST
     LIMIT 1;

    IF v_occurrence IS NULL THEN
        RAISE EXCEPTION 'Aucune séance à placer cette semaine-là'
              USING ERRCODE = 'no_data_found';
    END IF;

    UPDATE occurrence
       SET creneau  = v_creneau,
           id_lieu  = p_lieu,
           statut   = 'planifiee',
           epinglee = TRUE,
           motif    = NULL
     WHERE id_occurrence = v_occurrence;

    RETURN v_occurrence;
END $$;

COMMENT ON FUNCTION retenir_seance_sport IS
    'Fixe une séance sur un jour et un lieu choisis, et l''épingle pour que le
     replacement ne la déplace plus (SPT-13).';


-- -----------------------------------------------------------------------------
-- Un type de notification pour la proposition du lundi                  (SPT-13)
--
-- Le bot doit reconnaître ce message pour y accrocher les boutons de choix.
-- Le distinguer par son type vaut mieux que de relire son texte.
-- -----------------------------------------------------------------------------
ALTER TABLE notification DROP CONSTRAINT IF EXISTS notification_type_check;
ALTER TABLE notification ADD CONSTRAINT notification_type_check
    CHECK (type IN ('rappel', 'bilan', 'alerte', 'sport'));

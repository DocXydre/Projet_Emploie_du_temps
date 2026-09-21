-- rejouable : ALTER ... IF [NOT] EXISTS, CREATE OR REPLACE, DROP puis CREATE, et
--             des conversions gardées qui ne touchent que l'ancien modèle.
-- =============================================================================
-- 033 : organiser son sport soi-même                         (SPT-18 à SPT-27)
--
-- Le moteur posait trois séances par semaine là où il trouvait de la place, et
-- /organiser servait à corriger après coup. C'était l'inverse de l'usage : le
-- lundi matin, en amphi, on prend sa semaine en main et on choisit.
--
-- Le nouveau modèle distingue deux sortes de séances.
--
--   Choisie : décidée par soi, sport et heure compris. Épinglée, jamais
--   déplacée. Chaque choix est retenu dans `choix_sport`, et c'est de là que
--   naissent les habitudes : « piscine le mardi à 12h30 » revient en tête des
--   propositions quand il a été choisi souvent, et seulement s'il tient dans
--   l'emploi du temps de la semaine.
--
--   À déterminer : une réservation, pour que la semaine compte toujours au
--   moins trois séances. Elle occupe le calendrier, ce qui empêche le ménage de
--   s'y mettre, mais ne dit pas encore quel sport. Elle disparaît dès qu'on
--   choisit ; passée sans avoir été choisie, elle ne pose pas la question
--   « c'est fait ? » : un message le constate et la séance est reproposée plus
--   loin dans la semaine.
--
-- Ce qui reste du moteur d'avant : les lieux, leurs horaires et fermetures, le
-- trajet, les marges, la règle de repos, l'ancre après les cours. Ce qui part :
-- la génération des séances à placer, leur placement, la proposition du lundi
-- et le calcul de l'horizon.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 1. Le modèle
-- -----------------------------------------------------------------------------

-- Une réservation vient du minimum hebdomadaire : c'est son origine, et c'est
-- ce qui la tient à l'écart de PLA-7, qui efface les prévisions d'origine
-- « recurrence » à chaque validation.
ALTER TABLE occurrence DROP CONSTRAINT IF EXISTS occurrence_origine_check;
ALTER TABLE occurrence ADD CONSTRAINT occurrence_origine_check
    CHECK (origine IN ('recurrence', 'manuelle', 'enchainement', 'stock', 'quota'));

-- Une réservation n'est jamais épinglée : épingler, c'est choisir.
ALTER TABLE occurrence DROP CONSTRAINT IF EXISTS occurrence_quota_non_epinglee;
ALTER TABLE occurrence ADD CONSTRAINT occurrence_quota_non_epinglee
    CHECK (origine <> 'quota' OR NOT epinglee);

-- Le créneau d'une séance englobe le trajet et les marges. L'heure qu'on retient
-- et qu'on choisit, c'est celle du début de la séance elle-même.
ALTER TABLE occurrence ADD COLUMN IF NOT EXISTS debut_seance TIMESTAMPTZ;

COMMENT ON COLUMN occurrence.debut_seance IS
    'Sport : début de la séance proprement dite. Le créneau, lui, ajoute
     marge et trajet de part et d''autre (SPT-10).';


-- SPT-22 : chaque choix est retenu. Les habitudes en sont tirées, et rien
-- d'autre : pas de compteur à tenir à jour, pas de pourcentage stocké qui
-- vieillirait mal.
CREATE TABLE IF NOT EXISTS choix_sport (
    id_choix       SERIAL      PRIMARY KEY,
    id_utilisateur INTEGER     NOT NULL REFERENCES utilisateur (id_utilisateur),
    -- Supprimer une séance reprend le choix : il ne doit plus compter.
    id_occurrence  INTEGER     NOT NULL UNIQUE
                               REFERENCES occurrence (id_occurrence) ON DELETE CASCADE,
    id_lieu        INTEGER     NOT NULL REFERENCES lieu_sport (id_lieu) ON DELETE CASCADE,
    jour_semaine   SMALLINT    NOT NULL CHECK (jour_semaine BETWEEN 1 AND 7),
    heure          TIME        NOT NULL,
    semaine        DATE        NOT NULL CHECK (EXTRACT(ISODOW FROM semaine) = 1),
    origine        VARCHAR(12) NOT NULL DEFAULT 'proposition'
                               CHECK (origine IN ('proposition', 'habitude', 'modifiee',
                                                  'manuelle', 'reprise')),
    date_choix     TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS choix_sport_semaine_idx ON choix_sport (id_utilisateur, semaine);

COMMENT ON TABLE choix_sport IS
    'Une ligne par séance choisie : quel sport, quel jour de la semaine, à
     quelle heure. Modifier la séance modifie son choix ; la supprimer
     l''efface (SPT-22).';

COMMENT ON COLUMN choix_sport.origine IS
    'proposition : une proposition du moteur, prise telle quelle. habitude :
     une habitude reproposée. modifiee : une proposition dont on a changé
     l''heure ou le sport. manuelle : créée de toutes pièces. reprise : séance
     choisie avant la migration 033.';


-- Une séance ne se reporte pas au lendemain comme une tâche : elle est faite,
-- ou pas faite, et la semaine se réorganise autour (SPT-25).
UPDATE tache SET reportable = FALSE WHERE code = 'SPORT' AND reportable;


-- -----------------------------------------------------------------------------
-- 2. Ce que coûte une séance
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION duree_seance(p_lieu INTEGER) RETURNS INTERVAL
LANGUAGE sql STABLE AS $$
    SELECT make_interval(mins => COALESCE(l.duree_minutes, t.duree_minutes))
      FROM lieu_sport l, tache t
     WHERE l.id_lieu = p_lieu AND t.code = 'SPORT';
$$;


-- Le bloc à réserver : marge, trajet, séance, trajet, marge (SPT-10).
CREATE OR REPLACE FUNCTION bloc_de_seance(
    p_utilisateur INTEGER,
    p_lieu        INTEGER,
    p_debut       TIMESTAMPTZ
) RETURNS TSTZRANGE LANGUAGE sql STABLE AS $$
    SELECT tstzrange(p_debut - x.trajet - x.marge,
                     p_debut + duree_seance(p_lieu) + x.trajet + x.marge, '[)')
      FROM (SELECT make_interval(mins => trajet_minutes(p_utilisateur,
                                                        jour_de(p_debut), l.id_lieu)) AS trajet,
                   make_interval(mins => l.marge_minutes) AS marge
              FROM lieu_sport l
             WHERE l.id_lieu = p_lieu) x;
$$;


-- -----------------------------------------------------------------------------
-- 3. Ce qui empêche une séance                                  (SPT-19, SPT-21)
--
-- Rend la raison, ou NULL si rien n'empêche. Deux sévérités.
--
--   Stricte, pour ce que le système propose : le lieu est ouvert, le bloc
--   entier est libre, le repos est suffisant. Une proposition ne se fait que
--   si elle tient complètement.
--
--   Souple, pour ce qu'on choisit soi-même : seules les obligations comptent.
--   On sait parfois mieux que le moteur (SPT-17), mais on ne se met pas en
--   cours ni en service.
--
-- Les réservations « à déterminer » sont ignorées : elles sont là pour céder la
-- place à une vraie séance. Les tâches encore mobiles aussi : une séance passe
-- avant le ménage, qui se replace autour.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION obstacle_seance(
    p_utilisateur INTEGER,
    p_lieu        INTEGER,
    p_debut       TIMESTAMPTZ,
    p_ignorer     INTEGER DEFAULT NULL,
    p_strict      BOOLEAN DEFAULT TRUE
) RETURNS TEXT LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_jour   DATE := jour_de(p_debut);
    v_bloc   TSTZRANGE;
    v_duree  INTERVAL;
    v_raison TEXT;
BEGIN
    v_bloc  := bloc_de_seance(p_utilisateur, p_lieu, p_debut);
    v_duree := duree_seance(p_lieu);

    IF v_bloc IS NULL THEN
        RETURN 'Sport inconnu';
    END IF;

    -- Une proposition doit laisser le temps d'y aller ; un choix, seulement ne
    -- pas être déjà commencé.
    IF (p_strict AND lower(v_bloc) <= now()) OR p_debut <= now() THEN
        RETURN 'Ce moment est déjà passé';
    END IF;

    IF est_absent(p_utilisateur, v_jour) THEN
        RETURN 'Tu es absent ce jour-là';
    END IF;

    -- SPT-6 : une séance par jour.
    IF EXISTS (
        SELECT 1 FROM occurrence o
          JOIN tache t ON t.id_tache = o.id_tache
         WHERE o.id_utilisateur = p_utilisateur
           AND t.categorie = 'sport'
           AND o.origine <> 'quota'
           AND o.statut IN ('planifiee', 'notifiee', 'faite')
           AND o.id_occurrence IS DISTINCT FROM p_ignorer
           AND jour_de(COALESCE(o.debut_seance, lower(o.creneau))) = v_jour
    ) THEN
        RETURN 'Une séance est déjà prévue ce jour-là';
    END IF;

    -- On ne se met pas en cours ni en service, même quand on choisit.
    SELECT format('Ça tombe sur « %s »', o.libelle) INTO v_raison
      FROM occupation o
     WHERE o.id_utilisateur = p_utilisateur
       AND o.type IN ('cours', 'travail')
       AND o.periode && v_bloc
     ORDER BY lower(o.periode)
     LIMIT 1;
    IF v_raison IS NOT NULL THEN
        RETURN v_raison;
    END IF;

    -- Ce qui a été annoncé ou épinglé ne bouge plus (PLA-5) : une séance ne
    -- peut pas le recouvrir, choisie ou non.
    SELECT format('Ça tombe sur « %s »', t.libelle) INTO v_raison
      FROM occurrence o
      JOIN tache t ON t.id_tache = o.id_tache
     WHERE o.id_utilisateur = p_utilisateur
       AND o.creneau IS NOT NULL
       AND NOT o.rappel_journee
       AND o.statut IN ('planifiee', 'notifiee')
       AND o.origine <> 'quota'
       AND (o.epinglee OR o.statut = 'notifiee')
       AND o.id_occurrence IS DISTINCT FROM p_ignorer
       AND o.creneau && v_bloc
     LIMIT 1;
    IF v_raison IS NOT NULL THEN
        RETURN v_raison;
    END IF;

    IF NOT p_strict THEN
        RETURN NULL;
    END IF;

    -- Le reste de l'agenda : rendez-vous, calendriers personnels.
    SELECT format('Ça tombe sur « %s »', o.libelle) INTO v_raison
      FROM occupation o
     WHERE o.id_utilisateur = p_utilisateur
       AND o.periode && v_bloc
     ORDER BY lower(o.periode)
     LIMIT 1;
    IF v_raison IS NOT NULL THEN
        RETURN v_raison;
    END IF;

    -- SPT-2 : la séance entière tient dans une plage ouverte.
    IF NOT EXISTS (SELECT 1 FROM plages_ouvertes(p_lieu, v_jour) p
                    WHERE p @> tstzrange(p_debut, p_debut + v_duree, '[)')) THEN
        RETURN 'Le lieu est fermé à cette heure-là';
    END IF;

    -- SPT-7 : une séance tardive laisse dormir avant la prochaine obligation.
    IF NOT repos_suffisant(p_utilisateur, p_lieu, p_debut + v_duree) THEN
        RETURN 'Trop tard : pas assez de repos avant le lendemain';
    END IF;

    RETURN NULL;
END $$;

COMMENT ON FUNCTION obstacle_seance IS
    'Ce qui empêche une séance de ce sport à cette heure, ou NULL. Stricte pour
     les propositions, souple pour un choix (SPT-19, SPT-21).';


-- -----------------------------------------------------------------------------
-- 4. Les heures possibles un jour donné                                (SPT-24)
--
-- Au quart d'heure, dans les plages d'ouverture. Sert à proposer des heures
-- quand on modifie une séance, plutôt que de les faire écrire.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION heures_candidates(p_lieu INTEGER, p_jour DATE)
RETURNS SETOF TIMESTAMPTZ LANGUAGE sql STABLE AS $$
    SELECT DISTINCT h
      FROM plages_ouvertes(p_lieu, p_jour) p,
           LATERAL generate_series(
               -- Premier quart d'heure de la plage, arrondi vers le haut.
               date_bin(INTERVAL '15 minutes',
                        lower(p) + INTERVAL '15 minutes' - INTERVAL '1 microsecond',
                        debut_jour(p_jour)),
               upper(p) - duree_seance(p_lieu),
               INTERVAL '15 minutes') AS h
     ORDER BY h;
$$;


CREATE OR REPLACE FUNCTION heures_seance_sport(
    p_utilisateur INTEGER,
    p_lieu        INTEGER,
    p_jour        DATE,
    p_ignorer     INTEGER DEFAULT NULL
) RETURNS SETOF TIMESTAMPTZ LANGUAGE sql STABLE AS $$
    SELECT h FROM heures_candidates(p_lieu, p_jour) h
     WHERE obstacle_seance(p_utilisateur, p_lieu, h, p_ignorer, TRUE) IS NULL
     ORDER BY h;
$$;


-- -----------------------------------------------------------------------------
-- 5. La meilleure heure d'un sport un jour donné                (SPT-8, SPT-12)
--
-- Les préférences des lieux sont reprises telles quelles : la piscine au plus
-- tôt, la salle et la course juste après les cours, ou à l'heure par défaut
-- les jours sans cours.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION meilleure_heure_sport(
    p_utilisateur INTEGER,
    p_lieu        INTEGER,
    p_jour        DATE,
    p_ignorer     INTEGER DEFAULT NULL
) RETURNS TIMESTAMPTZ LANGUAGE plpgsql STABLE AS $$
DECLARE
    l       lieu_sport;
    v_ancre TIMESTAMPTZ;
    v_heure TIMESTAMPTZ;
BEGIN
    SELECT * INTO l FROM lieu_sport WHERE id_lieu = p_lieu;

    IF l.preference = 'apres' THEN
        -- Le bloc commence à la fin des cours : la séance, une fois la marge
        -- et le trajet passés.
        v_ancre := COALESCE(fin_des_cours(p_utilisateur, p_jour),
                            (p_jour + l.heure_defaut) AT TIME ZONE 'Europe/Paris')
                   + make_interval(mins => trajet_minutes(p_utilisateur, p_jour, p_lieu)
                                           + l.marge_minutes);
    END IF;

    FOR v_heure IN
        SELECT h FROM heures_candidates(p_lieu, p_jour) h
         ORDER BY CASE WHEN l.preference = 'tard' THEN h END DESC, h
    LOOP
        CONTINUE WHEN v_ancre IS NOT NULL AND v_heure < v_ancre;
        IF obstacle_seance(p_utilisateur, p_lieu, v_heure, p_ignorer, TRUE) IS NULL THEN
            RETURN v_heure;
        END IF;
    END LOOP;

    RETURN NULL;
END $$;


-- -----------------------------------------------------------------------------
-- 6. Les habitudes                                                     (SPT-22)
--
-- Un même sport, le même jour de la semaine, à la même heure. Son pourcentage
-- est la part des semaines où il a été choisi, sur les huit dernières : ce
-- qu'on fait souvent monte, ce qu'on a cessé de faire s'efface de lui-même.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION habitudes_sport(
    p_utilisateur INTEGER,
    p_reference   DATE DEFAULT NULL
) RETURNS TABLE (
    h_lieu        INTEGER,
    h_jour        SMALLINT,
    h_heure       TIME,
    h_semaines    INTEGER,
    h_total       INTEGER,
    h_pourcentage INTEGER
) LANGUAGE sql STABLE AS $$
    WITH fenetre AS (
        SELECT c.id_lieu, c.jour_semaine, c.heure, c.semaine
          FROM choix_sport c
         WHERE c.id_utilisateur = p_utilisateur
           AND c.semaine >= lundi_de(COALESCE(p_reference, jour_de(now()))) - 56
    ),
    total AS (SELECT count(DISTINCT f.semaine) AS n FROM fenetre f)
    SELECT f.id_lieu, f.jour_semaine, f.heure,
           count(DISTINCT f.semaine)::INTEGER,
           t.n::INTEGER,
           (100 * count(DISTINCT f.semaine) / t.n)::INTEGER
      FROM fenetre f, total t
     WHERE t.n > 0
     GROUP BY f.id_lieu, f.jour_semaine, f.heure, t.n;
$$;


-- -----------------------------------------------------------------------------
-- 7. Les propositions d'une semaine                           (SPT-20, SPT-22)
--
-- Jusqu'à cinq, une par jour. D'abord les habitudes qui tiennent entièrement
-- dans l'emploi du temps, de la plus fréquente à la plus rare. Puis le moteur :
-- le meilleur sport et la meilleure heure de chaque jour restant, en étalant
-- sur la semaine plutôt qu'en enchaînant trois jours de suite.
--
-- Le rang dit l'ordre de préférence. Les réservations prennent les premiers.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION propositions_sport(
    p_utilisateur INTEGER,
    p_lundi       DATE,
    p_ignorer     INTEGER DEFAULT NULL,
    p_jours_pris  DATE[]  DEFAULT NULL,
    p_max         INTEGER DEFAULT 5
) RETURNS TABLE (
    rang        INTEGER,
    jour        DATE,
    id_lieu     INTEGER,
    debut       TIMESTAMPTZ,
    bloc        TSTZRANGE,
    origine     VARCHAR,
    pourcentage INTEGER
) LANGUAGE plpgsql STABLE AS $$
#variable_conflict use_column
DECLARE
    v_tache    INTEGER;
    v_premier  DATE := GREATEST(p_lundi, jour_de(now()));
    v_pris     DATE[];
    v_n        INTEGER := 0;
    h          RECORD;
    l          RECORD;
    d          DATE;
    v_jour     DATE;
    v_debut    TIMESTAMPTZ;
    -- Candidats du moteur, un par jour.
    c_jour     DATE[] := ARRAY[]::DATE[];
    c_lieu     INTEGER[] := ARRAY[]::INTEGER[];
    c_debut    TIMESTAMPTZ[] := ARRAY[]::TIMESTAMPTZ[];
    c_rang     INTEGER[] := ARRAY[]::INTEGER[];
    i          INTEGER;
    v_meilleur INTEGER;
    v_ecart    INTEGER;
    v_ecart_max INTEGER;
BEGIN
    SELECT t.id_tache INTO v_tache FROM tache t WHERE t.code = 'SPORT' AND t.active;
    IF v_tache IS NULL OR p_max <= 0 THEN
        RETURN;
    END IF;

    -- Les jours qui ont déjà leur séance choisie, et ceux qu'on demande
    -- d'écarter (les réservations existantes, quand on complète).
    SELECT COALESCE(array_agg(DISTINCT jour_de(COALESCE(o.debut_seance, lower(o.creneau)))),
                    ARRAY[]::DATE[])
      INTO v_pris
      FROM occurrence o
     WHERE o.id_utilisateur = p_utilisateur
       AND o.id_tache = v_tache
       AND o.origine <> 'quota'
       AND o.statut IN ('planifiee', 'notifiee', 'faite')
       AND o.id_occurrence IS DISTINCT FROM p_ignorer
       AND jour_de(COALESCE(o.debut_seance, lower(o.creneau))) BETWEEN p_lundi AND p_lundi + 6;
    v_pris := v_pris || COALESCE(p_jours_pris, ARRAY[]::DATE[]);

    -- 1. Les habitudes qui tiennent.
    FOR h IN
        SELECT hs.*
          FROM habitudes_sport(p_utilisateur, p_lundi) hs
          JOIN tache_lieu tl ON tl.id_lieu = hs.h_lieu AND tl.id_tache = v_tache
         ORDER BY hs.h_pourcentage DESC, hs.h_semaines DESC, tl.rang,
                  hs.h_jour, hs.h_heure
    LOOP
        EXIT WHEN v_n >= p_max;
        v_jour := p_lundi + h.h_jour - 1;
        CONTINUE WHEN v_jour < v_premier OR v_jour = ANY(v_pris);

        v_debut := (v_jour + h.h_heure) AT TIME ZONE 'Europe/Paris';
        CONTINUE WHEN obstacle_seance(p_utilisateur, h.h_lieu, v_debut, p_ignorer, TRUE)
                      IS NOT NULL;

        v_n := v_n + 1;
        rang        := v_n;
        jour        := v_jour;
        id_lieu     := h.h_lieu;
        debut       := v_debut;
        bloc        := bloc_de_seance(p_utilisateur, h.h_lieu, v_debut);
        origine     := 'habitude';
        pourcentage := h.h_pourcentage;
        RETURN NEXT;
        v_pris := v_pris || v_jour;
    END LOOP;

    IF v_n >= p_max THEN
        RETURN;
    END IF;

    -- 2. Le moteur : pour chaque jour libre, le sport préféré qui y tient.
    d := v_premier;
    WHILE d <= p_lundi + 6 LOOP
        IF NOT (d = ANY(v_pris)) THEN
            FOR l IN SELECT tl.id_lieu, tl.rang FROM tache_lieu tl
                      WHERE tl.id_tache = v_tache ORDER BY tl.rang, tl.id_lieu LOOP
                v_debut := meilleure_heure_sport(p_utilisateur, l.id_lieu, d, p_ignorer);
                IF v_debut IS NOT NULL THEN
                    c_jour  := c_jour  || d;
                    c_lieu  := c_lieu  || l.id_lieu;
                    c_debut := c_debut || v_debut;
                    c_rang  := c_rang  || l.rang::INTEGER;
                    EXIT;
                END IF;
            END LOOP;
        END IF;
        d := d + 1;
    END LOOP;

    -- Étaler : on retient chaque fois le jour le plus éloigné de ce qui est
    -- déjà pris cette semaine. À égalité, le sport préféré, puis le plus tôt.
    WHILE v_n < p_max AND COALESCE(array_length(c_jour, 1), 0) > 0 LOOP
        v_meilleur := NULL;
        v_ecart_max := -1;
        FOR i IN 1 .. array_length(c_jour, 1) LOOP
            CONTINUE WHEN c_jour[i] IS NULL;
            SELECT COALESCE(min(abs(c_jour[i] - p)), 99) INTO v_ecart
              FROM unnest(v_pris) p
             WHERE p BETWEEN p_lundi AND p_lundi + 6;
            IF v_ecart > v_ecart_max
               OR (v_ecart = v_ecart_max AND c_rang[i] < c_rang[v_meilleur]) THEN
                v_meilleur := i;
                v_ecart_max := v_ecart;
            END IF;
        END LOOP;
        EXIT WHEN v_meilleur IS NULL;

        v_n := v_n + 1;
        rang        := v_n;
        jour        := c_jour[v_meilleur];
        id_lieu     := c_lieu[v_meilleur];
        debut       := c_debut[v_meilleur];
        bloc        := bloc_de_seance(p_utilisateur, c_lieu[v_meilleur], c_debut[v_meilleur]);
        origine     := 'moteur';
        pourcentage := NULL;
        RETURN NEXT;

        v_pris := v_pris || c_jour[v_meilleur];
        c_jour[v_meilleur] := NULL;
    END LOOP;
END $$;

COMMENT ON FUNCTION propositions_sport IS
    'Jusqu''à p_max séances proposées pour la semaine, une par jour : les
     habitudes qui tiennent, puis le moteur, étalé sur la semaine (SPT-20,
     SPT-22).';


-- -----------------------------------------------------------------------------
-- 8. Qui fait du sport
--
-- Le sport est personnel et ne se répartit pas. Sans assigné déclaré sur la
-- tâche, c'est le premier compte, comme avant.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION sportifs() RETURNS SETOF INTEGER
LANGUAGE sql STABLE AS $$
    SELECT COALESCE(t.id_utilisateur_defaut,
                    (SELECT min(u.id_utilisateur) FROM utilisateur u WHERE u.actif))
      FROM tache t
     WHERE t.code = 'SPORT' AND t.active;
$$;


-- -----------------------------------------------------------------------------
-- 9. Tenir le minimum d'une semaine                           (SPT-18, SPT-23)
--
-- Autant de réservations « à déterminer » qu'il en manque pour atteindre le
-- minimum, sur les meilleures propositions. Rien ne bouge tant que le compte
-- est bon : une réservation qui change de place à chaque collecte ne sert à
-- rien dans un calendrier.
--
-- Sauf quand on le demande (p_refaire) : après un choix, les habitudes ont
-- changé, et les réservations des autres semaines doivent en tenir compte.
-- -----------------------------------------------------------------------------
-- La première version n'avait pas p_refaire : sans ce DROP, les deux
-- coexisteraient et tout appel à deux arguments serait ambigu.
DROP FUNCTION IF EXISTS organiser_sport_semaine(INTEGER, DATE);

CREATE OR REPLACE FUNCTION organiser_sport_semaine(
    p_utilisateur INTEGER,
    p_lundi       DATE,
    p_refaire     BOOLEAN DEFAULT FALSE
) RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE
    v_tache     INTEGER;
    v_minimum   INTEGER;
    v_choisies  INTEGER;
    v_reservees INTEGER;
    v_manque    INTEGER;
    v_jours     DATE[];
    v_creees    INTEGER := 0;
    p           RECORD;
BEGIN
    SELECT t.id_tache, COALESCE(t.quota_hebdomadaire, 3)
      INTO v_tache, v_minimum
      FROM tache t WHERE t.code = 'SPORT' AND t.active;

    -- Une semaine passée ne se réorganise pas.
    IF v_tache IS NULL OR p_lundi + 7 <= jour_de(now()) THEN
        RETURN 0;
    END IF;

    -- Les réservations devenues fausses : jamais posées, ou tombées depuis un
    -- jour d'absence, un jour désormais choisi, ou sous une obligation apparue.
    DELETE FROM occurrence o
     WHERE o.id_utilisateur = p_utilisateur
       AND o.id_tache = v_tache
       AND o.origine = 'quota'
       AND o.statut IN ('a_placer', 'planifiee', 'notifiee')
       AND jour_de(COALESCE(o.debut_seance, lower(o.fenetre))) BETWEEN p_lundi AND p_lundi + 6
       AND (o.creneau IS NULL
            OR (lower(o.creneau) > now()
                AND (est_absent(p_utilisateur, jour_de(o.debut_seance))
                     OR EXISTS (SELECT 1 FROM occurrence c
                                 WHERE c.id_utilisateur = p_utilisateur
                                   AND c.id_tache = v_tache
                                   AND c.origine <> 'quota'
                                   AND c.statut IN ('planifiee', 'notifiee', 'faite')
                                   AND jour_de(COALESCE(c.debut_seance, lower(c.creneau)))
                                       = jour_de(o.debut_seance))
                     OR EXISTS (SELECT 1 FROM occupation oc
                                 WHERE oc.id_utilisateur = p_utilisateur
                                   AND oc.periode && o.creneau))));

    SELECT count(*) INTO v_choisies
      FROM occurrence o
     WHERE o.id_utilisateur = p_utilisateur
       AND o.id_tache = v_tache
       AND o.origine <> 'quota'
       AND o.statut IN ('planifiee', 'notifiee', 'faite')
       AND jour_de(COALESCE(o.debut_seance, lower(o.creneau))) BETWEEN p_lundi AND p_lundi + 6;

    -- Une réservation passée ne compte plus : elle attend d'être constatée
    -- (seances_a_determiner_passees), et une autre doit prendre le relais.
    SELECT count(*) INTO v_reservees
      FROM occurrence o
     WHERE o.id_utilisateur = p_utilisateur
       AND o.id_tache = v_tache
       AND o.origine = 'quota'
       AND o.statut IN ('planifiee', 'notifiee')
       AND lower(o.creneau) > now()
       AND jour_de(o.debut_seance) BETWEEN p_lundi AND p_lundi + 6;

    v_manque := v_minimum - v_choisies - v_reservees;

    -- Trop de réservations : une séance vient d'être choisie ailleurs. On
    -- repart des meilleures plutôt que de garder les restes. Celles déjà
    -- annoncées ce matin restent, sauf s'il le faut vraiment.
    IF (v_manque < 0 OR p_refaire) AND v_reservees > 0 THEN
        DELETE FROM occurrence o
         WHERE o.id_utilisateur = p_utilisateur
           AND o.id_tache = v_tache
           AND o.origine = 'quota'
           AND o.statut = 'planifiee'
           AND lower(o.creneau) > now()
           AND jour_de(o.debut_seance) BETWEEN p_lundi AND p_lundi + 6;

        SELECT count(*) INTO v_reservees
          FROM occurrence o
         WHERE o.id_utilisateur = p_utilisateur
           AND o.id_tache = v_tache
           AND o.origine = 'quota'
           AND o.statut = 'notifiee'
           AND lower(o.creneau) > now()
           AND jour_de(o.debut_seance) BETWEEN p_lundi AND p_lundi + 6;

        IF v_choisies + v_reservees > v_minimum THEN
            DELETE FROM occurrence o
             WHERE o.id_occurrence IN (
                   SELECT o2.id_occurrence FROM occurrence o2
                    WHERE o2.id_utilisateur = p_utilisateur
                      AND o2.id_tache = v_tache
                      AND o2.origine = 'quota'
                      AND o2.statut = 'notifiee'
                      AND lower(o2.creneau) > now()
                      AND jour_de(o2.debut_seance) BETWEEN p_lundi AND p_lundi + 6
                    ORDER BY o2.debut_seance DESC
                    LIMIT v_choisies + v_reservees - v_minimum);
            v_reservees := GREATEST(v_minimum - v_choisies, 0);
        END IF;

        v_manque := v_minimum - v_choisies - v_reservees;
    END IF;

    IF v_manque <= 0 THEN
        RETURN 0;
    END IF;

    SELECT COALESCE(array_agg(jour_de(o.debut_seance)), ARRAY[]::DATE[]) INTO v_jours
      FROM occurrence o
     WHERE o.id_utilisateur = p_utilisateur
       AND o.id_tache = v_tache
       AND o.origine = 'quota'
       AND o.statut IN ('planifiee', 'notifiee')
       AND jour_de(o.debut_seance) BETWEEN p_lundi AND p_lundi + 6;

    FOR p IN
        SELECT pr.*, ls.libelle AS lieu_libelle
          FROM propositions_sport(p_utilisateur, p_lundi, NULL, v_jours, v_manque) pr
          JOIN lieu_sport ls ON ls.id_lieu = pr.id_lieu
         ORDER BY pr.rang
    LOOP
        -- Ce qui était mobile dessous se replacera autour (SPT-23).
        UPDATE occurrence o
           SET creneau = NULL, statut = 'a_placer',
               motif = 'Déplacée par une réservation de sport'
         WHERE o.id_utilisateur = p_utilisateur
           AND o.statut = 'planifiee'
           AND NOT o.epinglee
           AND NOT o.rappel_journee
           AND o.origine <> 'quota'
           AND o.creneau && p.bloc;

        INSERT INTO occurrence (id_tache, id_utilisateur, fenetre, creneau, statut,
                                origine, id_lieu, debut_seance, motif)
        VALUES (v_tache, p_utilisateur,
                tstzrange(LEAST(debut_jour(p.jour), lower(p.bloc)),
                          GREATEST(debut_jour(p.jour + 1), upper(p.bloc)), '[)'),
                p.bloc, 'planifiee', 'quota', p.id_lieu, p.debut,
                format('À déterminer. Proposition : %s à %s. Choisis dans /organiser.',
                       p.lieu_libelle,
                       to_char(p.debut AT TIME ZONE 'Europe/Paris', 'HH24hMI')));

        v_creees := v_creees + 1;
    END LOOP;

    RETURN v_creees;
END $$;

COMMENT ON FUNCTION organiser_sport_semaine IS
    'Complète la semaine jusqu''au minimum de la tâche SPORT avec des
     réservations à déterminer, sur les meilleures propositions (SPT-18,
     SPT-23).';


-- SPT-18 : trois semaines, toujours.
CREATE OR REPLACE FUNCTION organiser_sport(p_utilisateur INTEGER DEFAULT NULL)
RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE
    u        INTEGER;
    i        INTEGER;
    v_creees INTEGER := 0;
BEGIN
    FOR u IN SELECT s FROM sportifs() s
              WHERE p_utilisateur IS NULL OR s = p_utilisateur LOOP
        FOR i IN 0 .. 2 LOOP
            v_creees := v_creees + organiser_sport_semaine(u, lundi_de(jour_de(now())) + 7 * i);
        END LOOP;
    END LOOP;
    RETURN v_creees;
END $$;


-- -----------------------------------------------------------------------------
-- 10. Choisir, modifier, supprimer                     (SPT-19, SPT-21, SPT-26)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION choisir_seance_sport(
    p_utilisateur INTEGER,
    p_lieu        INTEGER,
    p_debut       TIMESTAMPTZ,
    p_occurrence  INTEGER DEFAULT NULL,
    p_origine     VARCHAR DEFAULT 'proposition'
) RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE
    v_tache      INTEGER;
    v_obstacle   TEXT;
    v_bloc       TSTZRANGE;
    v_jour       DATE := jour_de(p_debut);
    v_ancien     DATE;
    v_occurrence INTEGER;
BEGIN
    SELECT t.id_tache INTO v_tache FROM tache t WHERE t.code = 'SPORT' AND t.active;
    IF v_tache IS NULL THEN
        RAISE EXCEPTION 'Le sport est désactivé' USING ERRCODE = 'no_data_found';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM tache_lieu tl
                    WHERE tl.id_tache = v_tache AND tl.id_lieu = p_lieu) THEN
        RAISE EXCEPTION 'Sport inconnu' USING ERRCODE = 'no_data_found';
    END IF;

    IF p_occurrence IS NOT NULL THEN
        SELECT jour_de(COALESCE(o.debut_seance, lower(o.creneau))) INTO v_ancien
          FROM occurrence o
         WHERE o.id_occurrence = p_occurrence
           AND o.id_utilisateur = p_utilisateur
           AND o.id_tache = v_tache
           AND o.origine <> 'quota'
           AND o.statut IN ('planifiee', 'notifiee');
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Séance introuvable, ou déjà passée'
                  USING ERRCODE = 'no_data_found';
        END IF;
    END IF;

    v_obstacle := obstacle_seance(p_utilisateur, p_lieu, p_debut, p_occurrence, FALSE);
    IF v_obstacle IS NOT NULL THEN
        RAISE EXCEPTION '%', v_obstacle USING ERRCODE = 'check_violation';
    END IF;

    v_bloc := bloc_de_seance(p_utilisateur, p_lieu, p_debut);

    -- La réservation du jour cède la place, et ce qui est mobile se replacera.
    DELETE FROM occurrence o
     WHERE o.id_utilisateur = p_utilisateur
       AND o.id_tache = v_tache
       AND o.origine = 'quota'
       AND o.statut IN ('a_placer', 'planifiee', 'notifiee')
       AND (jour_de(o.debut_seance) = v_jour OR o.creneau && v_bloc);

    UPDATE occurrence o
       SET creneau = NULL, statut = 'a_placer',
           motif = 'Déplacée par une séance de sport'
     WHERE o.id_utilisateur = p_utilisateur
       AND o.statut = 'planifiee'
       AND NOT o.epinglee
       AND NOT o.rappel_journee
       AND o.id_occurrence IS DISTINCT FROM p_occurrence
       AND o.creneau && v_bloc;

    IF p_occurrence IS NULL THEN
        INSERT INTO occurrence (id_tache, id_utilisateur, fenetre, creneau, statut,
                                origine, epinglee, id_lieu, debut_seance, motif)
        VALUES (v_tache, p_utilisateur,
                tstzrange(LEAST(debut_jour(v_jour), lower(v_bloc)),
                          GREATEST(debut_jour(v_jour + 1), upper(v_bloc)), '[)'),
                v_bloc, 'planifiee', 'manuelle', TRUE, p_lieu, p_debut, 'Choisie')
        RETURNING id_occurrence INTO v_occurrence;

        INSERT INTO choix_sport (id_utilisateur, id_occurrence, id_lieu, jour_semaine,
                                 heure, semaine, origine)
        VALUES (p_utilisateur, v_occurrence, p_lieu,
                EXTRACT(ISODOW FROM v_jour)::SMALLINT,
                (p_debut AT TIME ZONE 'Europe/Paris')::TIME,
                lundi_de(v_jour), p_origine);
    ELSE
        v_occurrence := p_occurrence;

        UPDATE occurrence o
           SET creneau      = v_bloc,
               fenetre      = tstzrange(LEAST(debut_jour(v_jour), lower(v_bloc)),
                                        GREATEST(debut_jour(v_jour + 1), upper(v_bloc)), '[)'),
               id_lieu      = p_lieu,
               debut_seance = p_debut,
               -- Déplacée à aujourd'hui, elle compte comme annoncée : la
               -- relance du soir doit la voir.
               statut       = CASE WHEN v_jour = jour_de(now()) THEN 'notifiee'
                                   ELSE 'planifiee' END,
               epinglee     = TRUE,
               motif        = 'Modifiée'
         WHERE o.id_occurrence = v_occurrence;

        -- SPT-22 : le choix suit la séance. L'habitude d'origine n'est pas
        -- touchée : elle perd seulement cette semaine-ci.
        INSERT INTO choix_sport (id_utilisateur, id_occurrence, id_lieu, jour_semaine,
                                 heure, semaine, origine)
        VALUES (p_utilisateur, v_occurrence, p_lieu,
                EXTRACT(ISODOW FROM v_jour)::SMALLINT,
                (p_debut AT TIME ZONE 'Europe/Paris')::TIME,
                lundi_de(v_jour), 'modifiee')
        ON CONFLICT (id_occurrence) DO UPDATE
           SET id_lieu      = EXCLUDED.id_lieu,
               jour_semaine = EXCLUDED.jour_semaine,
               heure        = EXCLUDED.heure,
               semaine      = EXCLUDED.semaine,
               origine      = 'modifiee',
               date_choix   = now();
    END IF;

    PERFORM organiser_sport_semaine(p_utilisateur, lundi_de(v_jour));
    IF v_ancien IS NOT NULL AND lundi_de(v_ancien) <> lundi_de(v_jour) THEN
        PERFORM organiser_sport_semaine(p_utilisateur, lundi_de(v_ancien));
    END IF;

    -- SPT-22 : le choix a déplacé les habitudes. Les autres semaines ouvertes
    -- reprennent leurs réservations sur les propositions du moment.
    PERFORM organiser_sport_semaine(p_utilisateur, lundi_de(jour_de(now())) + 7 * i, TRUE)
       FROM generate_series(0, 2) i
      WHERE lundi_de(jour_de(now())) + 7 * i NOT IN (lundi_de(v_jour),
                                                    COALESCE(lundi_de(v_ancien), lundi_de(v_jour)));

    RETURN v_occurrence;
END $$;

COMMENT ON FUNCTION choisir_seance_sport IS
    'Crée une séance choisie, ou modifie celle donnée : sport, jour, heure. Le
     choix est retenu pour les habitudes, la réservation du jour disparaît, et
     la semaine est recomplétée (SPT-19, SPT-21, SPT-22).';


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


-- -----------------------------------------------------------------------------
-- 11. Les réservations passées sans être choisies                      (SPT-25)
--
-- Pas de « c'est fait ? » : on ne l'avait pas choisie, on ne l'a donc pas
-- faite. Un message le dit, et rappelle ce qui reste réservé cette semaine,
-- la réservation manquée ayant été reproposée plus loin quand la semaine le
-- permet.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION seances_a_determiner_passees() RETURNS INTEGER
LANGUAGE plpgsql AS $$
DECLARE
    g         RECORD;
    v_reste   TEXT;
    v_contenu TEXT;
    v_n       INTEGER := 0;
BEGIN
    -- Groupées par personne et par semaine : si le serveur a dormi, trois
    -- réservations manquées font un message, pas trois.
    FOR g IN
        SELECT o.id_utilisateur, lundi_de(jour_de(o.debut_seance)) AS lundi,
               string_agg(to_char(o.debut_seance AT TIME ZONE 'Europe/Paris', 'DD/MM'),
                          ', ' ORDER BY o.debut_seance) AS jours,
               count(*) AS nombre
          FROM occurrence o
         WHERE o.origine = 'quota'
           AND o.statut IN ('planifiee', 'notifiee')
           AND upper(o.creneau) <= now()
         GROUP BY o.id_utilisateur, lundi_de(jour_de(o.debut_seance))
    LOOP
        UPDATE occurrence o
           SET statut = 'abandonnee',
               motif  = 'À déterminer, passée sans être choisie'
         WHERE o.origine = 'quota'
           AND o.id_utilisateur = g.id_utilisateur
           AND o.statut IN ('planifiee', 'notifiee')
           AND upper(o.creneau) <= now()
           AND lundi_de(jour_de(o.debut_seance)) = g.lundi;

        PERFORM organiser_sport_semaine(g.id_utilisateur, g.lundi);

        SELECT string_agg('• ' || to_char(o.debut_seance AT TIME ZONE 'Europe/Paris',
                                          'DD/MM à HH24hMI')
                          || COALESCE(' (proposé : ' || l.libelle || ')', ''),
                          E'\n' ORDER BY o.debut_seance)
          INTO v_reste
          FROM occurrence o
          LEFT JOIN lieu_sport l ON l.id_lieu = o.id_lieu
         WHERE o.id_utilisateur = g.id_utilisateur
           AND o.origine = 'quota'
           AND o.statut IN ('planifiee', 'notifiee')
           AND lower(o.creneau) > now()
           AND jour_de(o.debut_seance) BETWEEN g.lundi AND g.lundi + 6;

        v_contenu := format('Pas de sport le %s : la séance à déterminer est passée '
                            'sans être choisie.', g.jours);
        IF g.lundi + 7 <= jour_de(now()) THEN
            NULL;   -- la semaine est finie, il n'y a rien à reproposer
        ELSIF v_reste IS NOT NULL THEN
            v_contenu := v_contenu || E'\n\nCe qui reste réservé cette semaine :\n' || v_reste;
        ELSE
            v_contenu := v_contenu || E'\n\nPlus aucun créneau libre d''ici dimanche.';
        END IF;

        INSERT INTO notification (id_utilisateur, type, contenu)
        VALUES (g.id_utilisateur, 'sport', v_contenu);
        v_n := v_n + g.nombre;
    END LOOP;

    RETURN v_n;
END $$;


-- -----------------------------------------------------------------------------
-- 12. Le message du lundi                                              (SPT-27)
--
-- Rien quand la semaine est choisie. Sinon, ce qui manque et ce qui est
-- réservé en attendant.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION alerte_sport_du_lundi() RETURNS INTEGER
LANGUAGE plpgsql AS $$
DECLARE
    u          INTEGER;
    v_lundi    DATE := lundi_de(jour_de(now()));
    v_minimum  INTEGER;
    v_choisies INTEGER;
    v_reserve  TEXT;
    v_contenu  TEXT;
    v_n        INTEGER := 0;
BEGIN
    SELECT COALESCE(t.quota_hebdomadaire, 3) INTO v_minimum
      FROM tache t WHERE t.code = 'SPORT' AND t.active;
    IF v_minimum IS NULL THEN
        RETURN 0;
    END IF;

    FOR u IN SELECT s FROM sportifs() s LOOP
        PERFORM organiser_sport_semaine(u, v_lundi);

        SELECT count(*) INTO v_choisies
          FROM occurrence o
          JOIN tache t ON t.id_tache = o.id_tache
         WHERE o.id_utilisateur = u
           AND t.code = 'SPORT'
           AND o.origine <> 'quota'
           AND o.statut IN ('planifiee', 'notifiee', 'faite')
           AND jour_de(COALESCE(o.debut_seance, lower(o.creneau))) BETWEEN v_lundi AND v_lundi + 6;

        CONTINUE WHEN v_choisies >= v_minimum;

        SELECT string_agg('• ' || to_char(o.debut_seance AT TIME ZONE 'Europe/Paris',
                                          'DD/MM à HH24hMI')
                          || COALESCE(' (proposé : ' || l.libelle || ')', ''),
                          E'\n' ORDER BY o.debut_seance)
          INTO v_reserve
          FROM occurrence o
          LEFT JOIN lieu_sport l ON l.id_lieu = o.id_lieu
         WHERE o.id_utilisateur = u
           AND o.origine = 'quota'
           AND o.statut IN ('planifiee', 'notifiee')
           AND jour_de(o.debut_seance) BETWEEN v_lundi AND v_lundi + 6;

        v_contenu := CASE WHEN v_choisies = 0
                          THEN 'Sport : rien n''est choisi pour cette semaine.'
                          ELSE format('Sport : %s séance(s) choisie(s) sur %s minimum cette semaine.',
                                      v_choisies, v_minimum) END;
        IF v_reserve IS NOT NULL THEN
            v_contenu := v_contenu || E'\n\nÀ déterminer, réservé dans ton calendrier :\n'
                         || v_reserve;
        ELSE
            v_contenu := v_contenu || E'\n\nAucun créneau libre n''a pu être réservé.';
        END IF;

        INSERT INTO notification (id_utilisateur, type, contenu)
        VALUES (u, 'sport', v_contenu);
        v_n := v_n + 1;
    END LOOP;

    RETURN v_n;
END $$;


-- -----------------------------------------------------------------------------
-- 13. Le placement laisse le sport à son organisation                  (SPT-23)
--
-- Les séances ne passent plus par le placement général : choisies, elles sont
-- épinglées ; à déterminer, elles sont posées par organiser_sport, avant le
-- ménage, pour que le ménage se range autour.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION placer_taches(p_horizon_jours integer DEFAULT 35, p_stabilite_jours integer DEFAULT 7)
 RETURNS integer
 LANGUAGE plpgsql
AS $function$
DECLARE
    o         RECORD;
    v_creneau TSTZRANGE;
    v_duree   INTERVAL;
    v_places  INTEGER := 0;
    v_gele    TIMESTAMPTZ;
    v_assigne INTEGER;
    v_lieu    INTEGER;
BEGIN
    PERFORM generer_occurrences(p_horizon_jours);

    -- PLA-5, PLA-6 : un créneau notifié, épinglé, ou prévu dans les prochains jours
    -- ne bouge plus. Un planning qui change tous les matins ne sert à rien :
    -- on ne peut pas s'organiser autour de quelque chose qui se dérobe.
    v_gele := now() + make_interval(days => p_stabilite_jours);

    -- ABS-5 : exception au gel, quand la personne est absente ce jour-là.
    -- Sans elle, un départ déclaré pour le week-end prochain ne déplacerait
    -- aucune tâche, puisqu'il tombe dans la période gelée.
    UPDATE occurrence
       SET creneau = NULL, statut = 'a_placer', motif = NULL
     WHERE statut = 'planifiee'
       AND NOT epinglee
       -- SPT-23 : une réservation de sport n'est pas à replacer, elle est
       -- tenue par organiser_sport.
       AND origine <> 'quota'
       AND (creneau IS NULL
            OR lower(creneau) > v_gele
            OR (id_utilisateur IS NOT NULL
                AND est_absent(id_utilisateur, jour_de(lower(creneau)))));

    -- SPT-23 : les réservations de sport d'abord, le ménage se range autour.
    PERFORM organiser_sport();

    FOR o IN
        SELECT oc.id_occurrence, oc.id_tache, oc.id_utilisateur, oc.fenetre,
               oc.rappel_journee, oc.utilise_machine,
               t.duree_minutes, t.heure_min, t.heure_max,
               t.requiert_les_deux, t.libelle, t.categorie
          FROM occurrence oc
          JOIN tache t ON t.id_tache = oc.id_tache
         WHERE oc.statut = 'a_placer'
           -- Le sport ne passe plus par ici : une séance est choisie, ou
           -- réservée par organiser_sport.
           AND t.categorie <> 'sport'
           AND upper(oc.fenetre) > now()
           AND lower(oc.fenetre) < now() + make_interval(days => p_horizon_jours)
         ORDER BY t.priorite, upper(oc.fenetre), t.duree_minutes DESC
    LOOP
        -- ABS-2 : l'assigné se décide au placement, en fonction de qui est là.
        v_assigne := COALESCE(o.id_utilisateur, choisir_assigne(o.id_tache, o.fenetre));

        IF v_assigne IS NULL THEN
            -- ABS-4 : personne dans l'appartement sur toute la fenêtre. On ne
            -- salit pas ce qu'on n'habite pas : la tâche attend le retour.
            UPDATE occurrence
               SET id_utilisateur = NULL,
                   motif = 'Personne dans l''appartement sur cette période'
             WHERE id_occurrence = o.id_occurrence;
            CONTINUE;
        END IF;

        IF v_assigne IS DISTINCT FROM o.id_utilisateur THEN
            UPDATE occurrence SET id_utilisateur = v_assigne
             WHERE id_occurrence = o.id_occurrence;
        END IF;

        v_duree := make_interval(mins => o.duree_minutes);
        v_lieu := NULL;

        IF o.rappel_journee THEN
            v_creneau := chercher_jour(v_assigne, o.fenetre, v_duree);
        ELSE
            v_creneau := chercher_creneau(v_assigne, o.fenetre, v_duree,
                                          o.heure_min, o.heure_max, o.utilise_machine,
                                          o.requiert_les_deux);
        END IF;

        -- PLA-8 : une occurrence non plaçable n'est jamais supprimée. Elle garde
        -- son statut et reçoit un motif lisible.
        IF v_creneau IS NULL THEN
            UPDATE occurrence
               SET motif = CASE
                               WHEN o.requiert_les_deux THEN
                                   format('Aucun moment où vous êtes libres tous les deux avant le %s',
                                          to_char(upper(o.fenetre) AT TIME ZONE 'Europe/Paris', 'DD/MM'))
                               ELSE
                                   format('Aucune place de %s min avant le %s',
                                          o.duree_minutes,
                                          to_char(upper(o.fenetre) AT TIME ZONE 'Europe/Paris', 'DD/MM'))
                           END
             WHERE id_occurrence = o.id_occurrence;

            -- PLA-9 : aucun créneau commun aux deux personnes. On envoie une
            -- alerte au lieu de placer la tâche à un moment impossible.
            IF o.requiert_les_deux THEN
                INSERT INTO notification (id_utilisateur, id_occurrence, type, contenu)
                SELECT o.id_utilisateur, o.id_occurrence, 'alerte',
                       format('%s : aucun créneau commun trouvé avant le %s.',
                              o.libelle,
                              to_char(upper(o.fenetre) AT TIME ZONE 'Europe/Paris', 'DD/MM'))
                 WHERE o.id_utilisateur IS NOT NULL
                   AND NOT EXISTS (
                       SELECT 1 FROM notification n
                        WHERE n.id_occurrence = o.id_occurrence
                          AND n.statut = 'a_envoyer');
            END IF;
        ELSE
            UPDATE occurrence
               SET creneau = v_creneau,
                   statut  = 'planifiee',
                   id_lieu = v_lieu,
                   motif   = CASE
                                 WHEN v_lieu IS NOT NULL THEN
                                     format('%s le %s, trajet compris',
                                            (SELECT libelle FROM lieu_sport
                                              WHERE id_lieu = v_lieu),
                                            to_char(lower(v_creneau) AT TIME ZONE 'Europe/Paris', 'DD/MM à HH24hMI'))
                                 WHEN o.rappel_journee THEN
                                     format('À faire le %s',
                                            to_char(lower(v_creneau) AT TIME ZONE 'Europe/Paris', 'DD/MM'))
                                 ELSE
                                     format('Placée le %s',
                                            to_char(lower(v_creneau) AT TIME ZONE 'Europe/Paris', 'DD/MM à HH24hMI'))
                             END
             WHERE id_occurrence = o.id_occurrence;

            v_places := v_places + 1;
        END IF;
    END LOOP;

    RETURN v_places;
END $function$;


-- -----------------------------------------------------------------------------
-- 14. La relance du soir ne demande rien pour une réservation          (SPT-25)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION relance_du_soir()
 RETURNS integer
 LANGUAGE plpgsql
AS $function$
DECLARE
    o        RECORD;
    v_creees INTEGER := 0;
    v_jour   DATE := jour_de(now());
BEGIN
    FOR o IN
        SELECT oc.id_occurrence, oc.id_utilisateur,
               -- Pour une séance, le sport dit mieux que « Séance de sport ».
               COALESCE(l.libelle, t.libelle) AS libelle
          FROM occurrence oc
          JOIN tache t ON t.id_tache = oc.id_tache
          LEFT JOIN lieu_sport l ON l.id_lieu = oc.id_lieu
         WHERE oc.statut = 'notifiee'
           -- SPT-25 : une réservation qu'on n'a pas choisie ne se valide pas.
           AND oc.origine <> 'quota'
           AND oc.creneau IS NOT NULL
           AND jour_de(lower(oc.creneau)) = v_jour
           AND oc.id_utilisateur IS NOT NULL
         ORDER BY t.priorite
    LOOP
        -- Une seule relance par tâche et par soir.
        CONTINUE WHEN EXISTS (
            SELECT 1 FROM notification
             WHERE id_occurrence = o.id_occurrence
               AND type = 'rappel'
               AND jour_de(date_creation) = v_jour
        );

        INSERT INTO notification (id_utilisateur, id_occurrence, type, contenu)
        VALUES (o.id_utilisateur, o.id_occurrence, 'rappel',
                o.libelle || ' : c''est fait ?');

        v_creees := v_creees + 1;
    END LOOP;

    RETURN v_creees;
END $function$;


-- -----------------------------------------------------------------------------
-- 15. Le report de minuit ne reporte pas une séance                    (SPT-25)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION reporter_taches_du_jour()
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
DECLARE
    o             RECORD;
    v_reportees   INTEGER := 0;
    v_abandonnees INTEGER := 0;
    v_alertes     INTEGER := 0;
    v_demain      DATE := jour_de(now()) + 1;
BEGIN
    -- SPT-25 : les réservations de sport passées sont constatées d'abord,
    -- au cas où l'ordonnanceur ne l'aurait pas fait dans la journée.
    PERFORM seances_a_determiner_passees();

    -- 1. Ce qui avait un créneau et n'a pas été fait.
    FOR o IN
        SELECT oc.id_occurrence, oc.id_utilisateur, oc.creneau, oc.fenetre,
               oc.rappel_journee,
               t.reportable, t.libelle, t.abandon_apres_jours, t.categorie,
               v.jours_de_retard
          FROM occurrence oc
          JOIN tache t        ON t.id_tache = oc.id_tache
          JOIN v_occurrence v ON v.id_occurrence = oc.id_occurrence
         WHERE oc.statut IN ('planifiee', 'notifiee')
           AND oc.creneau IS NOT NULL
           AND upper(oc.creneau) <= now()
    LOOP
        IF o.abandon_apres_jours > 0 AND o.jours_de_retard >= o.abandon_apres_jours THEN
            PERFORM abandonner_occurrence(o.id_occurrence, o.jours_de_retard);
            v_abandonnees := v_abandonnees + 1;
            CONTINUE;
        END IF;

        -- SPT-25 : une séance choisie ne se reporte pas au lendemain. Elle
        -- attend sa réponse, faite ou pas faite, jusqu'à l'abandon.
        CONTINUE WHEN o.categorie = 'sport';

        -- Une lessive de travail en retard ne se reporte pas : le report ne
        -- résout rien, il faut le savoir tout de suite. Le compteur avance
        -- quand même, sans quoi elle paraîtrait à l'heure et ne serait jamais
        -- abandonnée.
        IF NOT o.reportable THEN
            UPDATE occurrence SET nb_relances = nb_relances + 1
             WHERE id_occurrence = o.id_occurrence;

            INSERT INTO notification (id_utilisateur, id_occurrence, type, contenu)
            VALUES (o.id_utilisateur, o.id_occurrence, 'alerte',
                    format('%s non faite et non reportable.', o.libelle));

            v_alertes := v_alertes + 1;
            CONTINUE;
        END IF;

        UPDATE occurrence
           SET creneau     = NULL,
               statut      = 'a_placer',
               nb_relances = nb_relances + 1,
               fenetre     = fenetre_pour(o.rappel_journee,
                                          lower(o.fenetre),
                                          GREATEST(upper(o.fenetre), debut_jour(v_demain + 1))),
               motif       = 'Reportée au lendemain, non faite'
         WHERE id_occurrence = o.id_occurrence;

        v_reportees := v_reportees + 1;
    END LOOP;

    -- 2. Ce qui n'a jamais trouvé de place et dont l'échéance est passée. Sans
    -- cette passe, une occurrence jamais posée n'était jamais vue par le report
    -- et restait indéfiniment dans la liste.
    FOR o IN
        SELECT oc.id_occurrence, v.jours_de_retard
          FROM occurrence oc
          JOIN tache t        ON t.id_tache = oc.id_tache
          JOIN v_occurrence v ON v.id_occurrence = oc.id_occurrence
         WHERE oc.statut = 'a_placer'
           AND upper(oc.fenetre) < now()
           AND t.abandon_apres_jours > 0
           AND v.jours_de_retard >= t.abandon_apres_jours
    LOOP
        PERFORM abandonner_occurrence(o.id_occurrence, o.jours_de_retard);
        v_abandonnees := v_abandonnees + 1;
    END LOOP;

    RETURN jsonb_build_object('reportees',   v_reportees,
                              'abandonnees', v_abandonnees,
                              'alertes',     v_alertes);
END $function$;


-- -----------------------------------------------------------------------------
-- 16. Le calendrier dit « à déterminer »                               (SPT-18)
--
-- Le lieu d'une réservation n'est qu'une suggestion : le montrer ferait croire
-- à un choix. Il reste dans le motif, que le calendrier affiche en description.
-- -----------------------------------------------------------------------------
DROP VIEW IF EXISTS v_planning;

CREATE VIEW v_planning AS
SELECT
    'occupation'                       AS nature,
    o.id_occupation::BIGINT            AS id,
    o.id_utilisateur,
    o.type                             AS categorie,
    o.libelle,
    o.periode,
    lower(o.periode)                   AS debut,
    upper(o.periode)                   AS fin,
    FALSE                              AS journee_entiere,
    NULL::VARCHAR                      AS statut,
    o.lieu,
    o.details                          AS motif,
    0                                  AS nb_relances
FROM occupation o

UNION ALL

SELECT
    'tache'                            AS nature,
    o.id_occurrence::BIGINT            AS id,
    o.id_utilisateur,
    t.categorie,
    CASE WHEN o.origine = 'quota' THEN t.libelle || ' à déterminer'
         ELSE t.libelle END            AS libelle,
    o.creneau                          AS periode,
    lower(o.creneau)                   AS debut,
    upper(o.creneau)                   AS fin,
    o.rappel_journee                   AS journee_entiere,
    o.statut,
    CASE WHEN o.origine = 'quota' THEN NULL ELSE l.libelle END AS lieu,
    o.motif,
    o.nb_relances
FROM occurrence o
JOIN tache t ON t.id_tache = o.id_tache
LEFT JOIN lieu_sport l ON l.id_lieu = o.id_lieu
WHERE o.creneau IS NOT NULL
  AND o.statut IN ('planifiee', 'notifiee')

UNION ALL

-- WKD-1 : une proposition n'occupe rien et ne gèle rien. Elle s'affiche pour
-- qu'on y pense, et quitte le calendrier dès qu'on a répondu.
SELECT
    'proposition'                      AS nature,
    p.id_proposition                   AS id,
    p.id_utilisateur,
    'trajet'                           AS categorie,
    'Week-end libre'
        || COALESCE(' à ' || p.lieu, '') || ' ?'  AS libelle,
    p.periode,
    lower(p.periode)                   AS debut,
    upper(p.periode)                   AS fin,
    TRUE                               AS journee_entiere,
    p.statut,
    p.lieu,
    'Repéré par le système : aucune obligation sur cette période' AS motif,
    0                                  AS nb_relances
FROM proposition p
WHERE p.statut = 'proposee';

COMMENT ON VIEW v_planning IS
    'Occupations, tâches placées et propositions dans une seule vue. Le drapeau
     journee_entiere décide si l''export produit un VEVENT horaire ou un
     VEVENT journée entière (NOT-3). Une réservation de sport s''y lit « à
     déterminer », sans lieu (SPT-18).';


-- -----------------------------------------------------------------------------
-- 17. Ce qui part avec l'ancien modèle
--
-- Les migrations 013 à 026 les définissent encore, et restent rejouables : si
-- l'une d'elles devait l'être, ce fichier-ci repasserait derrière elle.
-- -----------------------------------------------------------------------------
DROP FUNCTION IF EXISTS generer_seances_sport(INTEGER);
DROP FUNCTION IF EXISTS chercher_creneau_sport(INTEGER, INTEGER, TSTZRANGE, INTERVAL);
DROP FUNCTION IF EXISTS creneaux_sport_horizon(INTEGER, DATE);
DROP FUNCTION IF EXISTS creneaux_sport_semaine(INTEGER, DATE);
DROP FUNCTION IF EXISTS creneaux_sport_du_jour(INTEGER, INTEGER, DATE, INTERVAL);
DROP FUNCTION IF EXISTS seances_sport_a_caser(INTEGER, DATE);
DROP FUNCTION IF EXISTS seances_sport_restantes(INTEGER, DATE);
DROP FUNCTION IF EXISTS semaines_ouvertes(DATE);
DROP FUNCTION IF EXISTS retenir_seance_sport(INTEGER, DATE, INTEGER);
DROP FUNCTION IF EXISTS caler_seance_sport(INTEGER, TIMESTAMPTZ, INTEGER);


-- -----------------------------------------------------------------------------
-- 18. Les séances de l'ancien modèle
--
-- Celles que le moteur avait posées sans qu'on les choisisse laissent la place
-- aux réservations. Celles qu'on avait choisies restent, et amorcent les
-- habitudes, passées comme à venir. Le passé non choisi n'est pas touché.
-- -----------------------------------------------------------------------------
DELETE FROM occurrence o
 USING tache t
 WHERE t.id_tache = o.id_tache
   AND t.categorie = 'sport'
   AND NOT o.epinglee
   AND o.origine <> 'quota'
   AND o.statut IN ('a_placer', 'planifiee', 'notifiee')
   AND (o.creneau IS NULL OR lower(o.creneau) > now());

UPDATE occurrence o
   SET origine      = 'manuelle',
       debut_seance = lower(o.creneau)
                      + make_interval(mins => trajet_minutes(o.id_utilisateur,
                                                             jour_de(lower(o.creneau)),
                                                             o.id_lieu)
                                              + l.marge_minutes)
  FROM tache t, lieu_sport l
 WHERE t.id_tache = o.id_tache
   AND t.categorie = 'sport'
   AND l.id_lieu = o.id_lieu
   AND o.epinglee
   AND o.creneau IS NOT NULL
   AND o.debut_seance IS NULL;

INSERT INTO choix_sport (id_utilisateur, id_occurrence, id_lieu, jour_semaine, heure,
                         semaine, origine, date_choix)
SELECT o.id_utilisateur, o.id_occurrence, o.id_lieu,
       EXTRACT(ISODOW FROM jour_de(o.debut_seance))::SMALLINT,
       (o.debut_seance AT TIME ZONE 'Europe/Paris')::TIME,
       lundi_de(jour_de(o.debut_seance)), 'reprise', o.debut_seance
  FROM occurrence o
  JOIN tache t ON t.id_tache = o.id_tache
 WHERE t.categorie = 'sport'
   AND o.epinglee
   AND o.id_lieu IS NOT NULL
   AND o.debut_seance IS NOT NULL
   AND o.id_utilisateur IS NOT NULL
   AND o.statut IN ('planifiee', 'notifiee', 'faite')
ON CONFLICT (id_occurrence) DO NOTHING;

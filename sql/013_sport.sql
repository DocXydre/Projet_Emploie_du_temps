-- rejouable : DROP/ADD de contrainte, CREATE TABLE IF NOT EXISTS, INSERT
--             idempotents et CREATE OR REPLACE.
-- =============================================================================
-- 013 : séances de sport                                      (SPT-1 à SPT-8)
--
-- Une séance ressemble à une tâche, avec trois différences : le lieu a des
-- heures d'ouverture, le trajet aller-retour occupe l'agenda, et le quota se
-- compte par semaine et non par période.
-- =============================================================================


-- Le sport n'est pas du ménage, et la catégorie décide du préfixe au
-- calendrier autant que du regroupement.
ALTER TABLE tache DROP CONSTRAINT IF EXISTS tache_categorie_check;
ALTER TABLE tache ADD CONSTRAINT tache_categorie_check
    CHECK (categorie IN ('menage', 'linge', 'vaisselle', 'animal', 'admin', 'sport'));


-- -----------------------------------------------------------------------------
-- Lieux                                                              (SPT-1, SPT-4)
--
-- Deux distances, parce qu'on ne part pas toujours du même endroit. Un jour de
-- cours, la piscine du SUAPS est à cinq minutes de l'amphi ; un jour sans, elle
-- est à vingt minutes de l'appartement.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS lieu_sport (
    id_lieu          SERIAL       PRIMARY KEY,
    code             VARCHAR(30)  NOT NULL UNIQUE,
    libelle          VARCHAR(100) NOT NULL,

    minutes_domicile SMALLINT     NOT NULL CHECK (minutes_domicile >= 0),
    minutes_fac      SMALLINT     NOT NULL CHECK (minutes_fac >= 0),

    -- Bornes du raisonnable, même pour un lieu ouvert jour et nuit : personne
    -- ne veut se voir proposer une séance à 4h du matin sous prétexte que la
    -- salle est ouverte.
    heure_min        TIME         NOT NULL DEFAULT '07:00',
    heure_max        TIME         NOT NULL DEFAULT '22:00',

    -- SPT-7 : au-delà de cette heure, une séance empiète sur la nuit. On exige
    -- alors un repos avant la prochaine obligation.
    heure_tardive    TIME,
    repos_heures     SMALLINT     NOT NULL DEFAULT 0 CHECK (repos_heures >= 0),

    -- SPT-8 : placer la séance au plus tôt ou au plus tard dans le creux. La
    -- piscine n'ouvre que deux heures à midi, on prend au plus tôt ; la salle
    -- est ouverte 24h/24, on prend au plus tard.
    preference       VARCHAR(4)   NOT NULL DEFAULT 'tot'
                                  CHECK (preference IN ('tot', 'tard')),

    CONSTRAINT lieu_heures_coherentes CHECK (heure_max > heure_min),
    CONSTRAINT lieu_repos_coherent
        CHECK (repos_heures = 0 OR heure_tardive IS NOT NULL)
);


-- -----------------------------------------------------------------------------
-- Heures d'ouverture                                                      (SPT-2)
--
-- Un lieu sans aucune ligne d'ouverture est réputé ouvert en permanence, dans
-- les bornes de `heure_min` et `heure_max`. C'est le cas de la salle, et ça
-- évite d'écrire sept lignes identiques pour dire « toujours ».
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ouverture (
    id_ouverture SERIAL   PRIMARY KEY,
    id_lieu      INTEGER  NOT NULL REFERENCES lieu_sport (id_lieu) ON DELETE CASCADE,
    -- 1 = lundi, 7 = dimanche, comme ISODOW.
    jour_semaine SMALLINT NOT NULL CHECK (jour_semaine BETWEEN 1 AND 7),
    heure_debut  TIME     NOT NULL,
    heure_fin    TIME     NOT NULL,

    CONSTRAINT ouverture_bornee CHECK (heure_fin > heure_debut),
    CONSTRAINT ouverture_unique UNIQUE (id_lieu, jour_semaine, heure_debut)
);


-- -----------------------------------------------------------------------------
-- Fermetures                                                             (SPT-3)
--
-- Les heures d'ouverture décrivent une semaine type. Cette table ajoute les
-- périodes de fermeture : été, vacances de Noël, entre-deux-semestres. Le
-- SUAPS ferme plus de trois mois par an.
--
-- Les fermetures se comptent en jours pleins, pas en instants.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS fermeture (
    id_fermeture SERIAL       PRIMARY KEY,
    id_lieu      INTEGER      NOT NULL REFERENCES lieu_sport (id_lieu)
                              ON DELETE CASCADE,
    periode      DATERANGE    NOT NULL CHECK (NOT isempty(periode)),
    motif        VARCHAR(200),

    -- Deux fermetures d'un même lieu qui se chevauchent sont une saisie en
    -- double, pas deux informations.
    CONSTRAINT fermeture_sans_chevauchement
        EXCLUDE USING gist (id_lieu WITH =, periode WITH &&)
);


-- Une tâche de sport se rattache à un ou plusieurs lieux, par ordre de
-- préférence : la piscine d'abord, la salle si la piscine ne peut pas.
CREATE TABLE IF NOT EXISTS tache_lieu (
    id_tache INTEGER  NOT NULL REFERENCES tache (id_tache) ON DELETE CASCADE,
    id_lieu  INTEGER  NOT NULL REFERENCES lieu_sport (id_lieu) ON DELETE CASCADE,
    rang     SMALLINT NOT NULL DEFAULT 1,
    PRIMARY KEY (id_tache, id_lieu)
);

-- SPT-5 : le quota est hebdomadaire. NULL pour tout ce qui garde une périodicité.
ALTER TABLE tache ADD COLUMN IF NOT EXISTS quota_hebdomadaire SMALLINT
    CHECK (quota_hebdomadaire IS NULL OR quota_hebdomadaire > 0);

-- Le lieu est décidé au placement, pas à la création : c'est là qu'on sait si
-- la piscine est ouverte et si le trajet tient dans le creux.
ALTER TABLE occurrence ADD COLUMN IF NOT EXISTS id_lieu INTEGER
    REFERENCES lieu_sport (id_lieu) ON DELETE SET NULL;


-- -----------------------------------------------------------------------------
-- Semaine ISO
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION lundi_de(p_jour DATE) RETURNS DATE
LANGUAGE sql IMMUTABLE AS $$
    SELECT p_jour - (EXTRACT(ISODOW FROM p_jour)::INTEGER - 1);
$$;


-- -----------------------------------------------------------------------------
-- Trajet à prévoir un jour donné                                          (SPT-4)
--
-- On ne sait pas où l'on sera à l'heure près, seulement si l'on a cours ce
-- jour-là. L'approximation retenue est la plus prudente : on compte le trajet
-- le plus long des deux.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trajet_minutes(
    p_utilisateur INTEGER,
    p_jour        DATE,
    p_lieu        INTEGER
) RETURNS INTEGER LANGUAGE sql STABLE AS $$
    SELECT CASE
        WHEN EXISTS (
            SELECT 1 FROM occupation o
             WHERE o.id_utilisateur = p_utilisateur
               AND o.type = 'cours'
               AND o.periode && tstzrange(debut_jour(p_jour),
                                          debut_jour(p_jour + 1), '[)')
        ) THEN l.minutes_fac
        ELSE l.minutes_domicile
    END
      FROM lieu_sport l WHERE l.id_lieu = p_lieu;
$$;


-- -----------------------------------------------------------------------------
-- Plages ouvertes un jour donné                                           (SPT-2)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION plages_ouvertes(p_lieu INTEGER, p_jour DATE)
RETURNS SETOF TSTZRANGE LANGUAGE sql STABLE AS $$
    WITH bornes AS (
        -- SPT-3 : un lieu fermé ce jour-là n'a aucune plage, quelles que soient
        -- ses heures habituelles.
        SELECT l.heure_min, l.heure_max
          FROM lieu_sport l
         WHERE l.id_lieu = p_lieu
           AND NOT EXISTS (SELECT 1 FROM fermeture f
                            WHERE f.id_lieu = p_lieu
                              AND f.periode @> p_jour)
    ),
    declarees AS (
        SELECT tstzrange((p_jour + o.heure_debut) AT TIME ZONE 'Europe/Paris',
                         (p_jour + o.heure_fin)   AT TIME ZONE 'Europe/Paris',
                         '[)') AS plage
          FROM ouverture o
         WHERE o.id_lieu = p_lieu
           AND o.jour_semaine = EXTRACT(ISODOW FROM p_jour)::SMALLINT
    ),
    -- Un lieu qui n'a AUCUN horaire déclaré est ouvert en permanence : c'est
    -- la salle, et cela évite d'écrire sept lignes pour dire « toujours ».
    --
    -- La nuance porte tout : « aucune plage ce jour-là » n'est pas « ouvert
    -- en permanence ». La piscine n'ayant rien le dimanche, la première
    -- version proposait un bain à 6h40 devant une porte close.
    toutes AS (
        SELECT plage FROM declarees
        UNION ALL
        SELECT tstzrange((p_jour + b.heure_min) AT TIME ZONE 'Europe/Paris',
                         (p_jour + b.heure_max) AT TIME ZONE 'Europe/Paris',
                         '[)')
          FROM bornes b
         WHERE NOT EXISTS (SELECT 1 FROM ouverture o WHERE o.id_lieu = p_lieu)
    )
    SELECT t.plage
             * tstzrange((p_jour + b.heure_min) AT TIME ZONE 'Europe/Paris',
                         (p_jour + b.heure_max) AT TIME ZONE 'Europe/Paris', '[)')
      FROM toutes t, bornes b
     WHERE NOT isempty(
               t.plage * tstzrange((p_jour + b.heure_min) AT TIME ZONE 'Europe/Paris',
                                   (p_jour + b.heure_max) AT TIME ZONE 'Europe/Paris', '[)'))
     ORDER BY 1;
$$;


-- -----------------------------------------------------------------------------
-- Repos avant la prochaine obligation                                     (SPT-7)
--
-- Ne mord que sur les séances tardives. Une séance de 14h suivie d'un cours à
-- 18h ne pose aucun problème ; c'est celle de 22h30 avant un cours à 8h qui en
-- pose un.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION repos_suffisant(
    p_utilisateur INTEGER,
    p_lieu        INTEGER,
    p_fin         TIMESTAMPTZ
) RETURNS BOOLEAN LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_lieu      lieu_sport;
    v_prochaine TIMESTAMPTZ;
BEGIN
    SELECT * INTO v_lieu FROM lieu_sport WHERE id_lieu = p_lieu;

    IF v_lieu.heure_tardive IS NULL OR v_lieu.repos_heures = 0 THEN
        RETURN TRUE;
    END IF;

    IF (p_fin AT TIME ZONE 'Europe/Paris')::TIME < v_lieu.heure_tardive THEN
        RETURN TRUE;
    END IF;

    SELECT min(lower(o.periode)) INTO v_prochaine
      FROM occupation o
     WHERE o.id_utilisateur = p_utilisateur
       AND o.type IN ('cours', 'travail')
       AND lower(o.periode) >= p_fin;

    RETURN v_prochaine IS NULL
        OR v_prochaine - p_fin >= make_interval(hours => v_lieu.repos_heures);
END $$;


-- -----------------------------------------------------------------------------
-- Chercher un créneau de sport
--
-- La fonction est définie dans la migration 016, avec les marges, les durées
-- par lieu et l'ancrage sur la fin des cours. Elle a été retirée d'ici : les
-- deux fichiers sont rejouables, et rejouer celui-ci après une correction
-- aurait remis en place la version qui posait la salle à 21h les jours vides.
-- -----------------------------------------------------------------------------


-- -----------------------------------------------------------------------------
-- Engendrer les séances de la semaine                                     (SPT-5)
--
-- Une occurrence par séance due, avec la semaine entière pour fenêtre. Le
-- placement se charge ensuite de les répartir — c'est lui qui sait quels jours
-- sont libres, pas cette fonction.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION generer_seances_sport(p_horizon_jours INTEGER DEFAULT 35)
RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE
    t          RECORD;
    u          RECORD;
    v_lundi    DATE;
    v_fin      DATE;
    v_existant INTEGER;
    v_creees   INTEGER := 0;
BEGIN
    v_fin := jour_de(now()) + p_horizon_jours;

    FOR t IN SELECT * FROM tache
              WHERE active AND quota_hebdomadaire IS NOT NULL LOOP
        FOR u IN SELECT id_utilisateur FROM utilisateur
                  WHERE actif
                    AND (t.id_utilisateur_defaut IS NULL
                         OR id_utilisateur = t.id_utilisateur_defaut)
                  ORDER BY id_utilisateur LOOP

            -- Une tâche sans assigné fixe ne concerne que son propriétaire
            -- déclaré : le sport ne se répartit pas entre colocataires.
            CONTINUE WHEN t.id_utilisateur_defaut IS NULL
                      AND u.id_utilisateur <> (SELECT min(id_utilisateur)
                                                 FROM utilisateur WHERE actif);

            v_lundi := lundi_de(jour_de(now()));
            WHILE v_lundi <= v_fin LOOP
                SELECT count(*) INTO v_existant
                  FROM occurrence o
                 WHERE o.id_tache = t.id_tache
                   AND o.id_utilisateur = u.id_utilisateur
                   AND lower(o.fenetre) = debut_jour(v_lundi)
                   AND o.statut <> 'abandonnee';

                WHILE v_existant < t.quota_hebdomadaire LOOP
                    INSERT INTO occurrence (id_tache, id_utilisateur, fenetre,
                                            statut, origine)
                    VALUES (t.id_tache, u.id_utilisateur,
                            tstzrange(debut_jour(v_lundi),
                                      debut_jour(v_lundi + 7), '[)'),
                            'a_placer', 'recurrence');
                    v_existant := v_existant + 1;
                    v_creees := v_creees + 1;
                END LOOP;

                v_lundi := v_lundi + 7;
            END LOOP;
        END LOOP;
    END LOOP;

    RETURN v_creees;
END $$;


-- =============================================================================
-- Données : les lieux de Thomas
-- =============================================================================

INSERT INTO lieu_sport (code, libelle, minutes_domicile, minutes_fac,
                        heure_min, heure_max, heure_tardive, repos_heures, preference)
VALUES
    -- La piscine universitaire : cinq minutes de l'amphi, vingt de
    -- l'appartement. Ses horaires publics sont déclarés plus bas.
    ('PISCINE_SUAPS', 'Piscine du SUAPS', 20, 5, '07:00', '20:00', NULL, 0, 'tot'),

    -- La salle est ouverte jour et nuit, mais une séance qui finit tard doit
    -- laisser dix heures avant le prochain cours ou service.
    ('SALLE', 'Salle de musculation', 20, 20, '09:00', '23:30', '21:00', 10, 'tard')
ON CONFLICT (code) DO NOTHING;


-- Créneaux publics de la piscine : midi et fin d'après-midi, en semaine.
-- Le créneau de midi vient en premier, et c'est celui que le moteur retiendra
-- puisqu'il prend le plus tôt possible.
INSERT INTO ouverture (id_lieu, jour_semaine, heure_debut, heure_fin)
SELECT l.id_lieu, j.jour, h.debut, h.fin
  FROM lieu_sport l
  CROSS JOIN generate_series(1, 5) AS j(jour)
  CROSS JOIN (VALUES (TIME '12:00', TIME '14:00'),
                     (TIME '16:00', TIME '17:00')) AS h(debut, fin)
 WHERE l.code = 'PISCINE_SUAPS'
ON CONFLICT (id_lieu, jour_semaine, heure_debut) DO NOTHING;


-- Pause estivale 2026, telle que le SUAPS l'annonce sur sport.univ-lorraine.fr :
-- « Fin des enseignements pour cette année universitaire 2025/26. Reprise des
-- activités le 07 septembre 2026. » La borne haute d'un DATERANGE est exclue,
-- donc le 7 septembre est bien le premier jour ouvert.
INSERT INTO fermeture (id_lieu, periode, motif)
SELECT l.id_lieu, DATERANGE('2026-07-01', '2026-09-07', '[)'),
       'Pause estivale — reprise annoncée le 7 septembre 2026'
  FROM lieu_sport l
 WHERE l.code = 'PISCINE_SUAPS'
   AND NOT EXISTS (SELECT 1 FROM fermeture f
                    WHERE f.id_lieu = l.id_lieu
                      AND f.periode && DATERANGE('2026-07-01', '2026-09-07', '[)'));


INSERT INTO tache (code, libelle, categorie, priorite, duree_minutes,
                   periodicite_min_jours, periodicite_max_jours,
                   rappel_journee, heure_min, heure_max,
                   quota_hebdomadaire, recurrente)
VALUES ('SPORT', 'Séance de sport', 'sport', 2, 60, 2, 7,
        FALSE, '07:00', '23:30', 3, FALSE)
ON CONFLICT (code) DO NOTHING;


-- Piscine d'abord, salle ensuite : c'est la préférence, pas une exclusivité.
INSERT INTO tache_lieu (id_tache, id_lieu, rang)
SELECT t.id_tache, l.id_lieu,
       CASE l.code WHEN 'PISCINE_SUAPS' THEN 1 ELSE 2 END
  FROM tache t, lieu_sport l
 WHERE t.code = 'SPORT' AND l.code IN ('PISCINE_SUAPS', 'SALLE')
ON CONFLICT (id_tache, id_lieu) DO NOTHING;


-- -----------------------------------------------------------------------------
-- Planning consolidé                                                (NOT-3, WKD-1)
--
-- Définie ici, et non avec les autres vues : elle lit `proposition` et
-- `lieu_sport`, créées en 012 et 013. Une vue ne peut pas précéder ses tables.
--
-- DROP puis CREATE, car la colonne `id` passe d'INTEGER à BIGINT :
-- CREATE OR REPLACE VIEW refuse un changement de type. Pas de CASCADE, pour
-- que la migration échoue si une vue dépendait de celle-ci.
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
    t.libelle,
    o.creneau                          AS periode,
    lower(o.creneau)                   AS debut,
    upper(o.creneau)                   AS fin,
    o.rappel_journee                   AS journee_entiere,
    o.statut,
    l.libelle                          AS lieu,
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
     VEVENT journée entière (NOT-3).';



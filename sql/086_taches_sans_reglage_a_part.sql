-- =============================================================================
-- 086 : les tâches sans réglage à part          (TAC-29 à TAC-31, MTA, VER, lot 18)
--
-- Rejouable. Ce qui lit les colonnes d'avant ne passe que tant qu'elles sont
-- là : au deuxième passage, elles sont parties, et seul le reste se rejoue.
--
-- Plus aucune tâche n'a de réglage à elle seule. Les tâches d'origine avaient
-- des colonnes que le formulaire ne montrait pas (avant un départ, au retour,
-- une machine par jour, à deux, le bloc « Nettoyage », sans report). Ce
-- qu'elles disaient est écrit ici dans la description de chaque tâche, que HAL
-- tient et applique ; puis les colonnes partent (annexe 15).
--
-- Arrivent en même temps : la description des tâches, la file des
-- vérifications, l'épingle par HAL, le jour de la vérification de la semaine,
-- les tâches arrêtées datées et les cinq types de base.
--
-- Les fonctions sont dans sql/definitions/ ; celles qui partent, ou dont la
-- signature change, sont retirées ici.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 1. Ce qui appliquait les réglages à part
-- -----------------------------------------------------------------------------
DROP TRIGGER IF EXISTS occurrence_machine_unique ON occurrence;
DROP FUNCTION IF EXISTS trg_machine_unique();
DROP FUNCTION IF EXISTS machine_occupee(DATE, INTEGER);
DROP FUNCTION IF EXISTS taches_avant_depart(INTEGER);
DROP FUNCTION IF EXISTS taches_au_retour(INTEGER);
DROP FUNCTION IF EXISTS journee_libre(INTEGER, DATE);
DROP FUNCTION IF EXISTS ajouter_tache(TEXT, INTEGER, INTEGER, DATE, INTEGER, INTEGER);

-- Les signatures qui changent : la machine et le créneau commun quittent la
-- recherche d'un créneau ; une tâche se déclare faite par son numéro ; la
-- création sait aussi « selon la description ».
DROP FUNCTION IF EXISTS chercher_creneau(INTEGER, TSTZRANGE, INTERVAL, TIME, TIME, BOOLEAN, BOOLEAN);
DROP FUNCTION IF EXISTS declarer_faite(INTEGER, VARCHAR, TIMESTAMPTZ);
DROP FUNCTION IF EXISTS creer_tache(TEXT, INTEGER, INTEGER, INTEGER, INTEGER, INTEGER, DATE, DATE,
                                    INTEGER, INTEGER, INTEGER, TIME, TIME, TEXT, INTEGER);


-- -----------------------------------------------------------------------------
-- 2. Les descriptions des tâches                                  (MTA-1, MTA-4)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS description_tache (
    id_description_tache BIGINT      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    id_tache             INTEGER     NOT NULL REFERENCES tache (id_tache) ON DELETE CASCADE,
    texte                TEXT        NOT NULL,
    dite_par             INTEGER     REFERENCES utilisateur (id_utilisateur),
    id_appel             BIGINT      REFERENCES appel_coach (id_appel) ON DELETE SET NULL,
    quand                TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT description_tache_longueur CHECK (length(texte) <= 1000)
);

CREATE INDEX IF NOT EXISTS description_tache_en_vigueur
    ON description_tache (id_tache, id_description_tache DESC);

COMMENT ON TABLE description_tache IS
    'MTA-1 : la description d''une tâche, ce que le formulaire ne sait pas dire. HAL la tient et l''applique ; le moteur ne la lit pas. Une ligne par version ; la dernière est en vigueur.';


-- -----------------------------------------------------------------------------
-- 3. Ce que les tâches d'origine avaient de plus             (TAC-29, annexe 15)
--
-- Écrit d'après les colonnes telles qu'elles sont encore : une case décochée
-- depuis, à la main ou par le rattrapage 080, n'écrit rien. Le texte est celui
-- qu'on dirait à HAL.
-- -----------------------------------------------------------------------------
DO $etape$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                    WHERE table_schema = 'public' AND table_name = 'tache'
                      AND column_name = 'avant_depart') THEN
        RETURN;
    END IF;
    WITH phrases AS (
        SELECT t.id_tache, concat_ws(' ',
            CASE WHEN t.code = 'POUBELLES' AND NOT t.reportable
                 THEN 'Ne se repousse pas : un sac qui attend se sent.'
                 WHEN NOT t.reportable AND t.recurrente
                 THEN 'Ne se décale pas : à faire le jour prévu.' END,
            CASE WHEN t.avant_depart AND t.code = 'POUBELLES'
                 THEN 'Quand l''appartement va se vider, à sortir avant que le dernier parte, en plus '
                      'du rythme, même si elles ont été sorties deux jours plus tôt. Le ramassage passe '
                      'à l''aube : un départ avant 17 h la fait tomber la veille au soir.'
                 WHEN t.avant_depart AND t.code = 'LITIERE_VIDAGE'
                 THEN 'Quand l''appartement va se vider, la caisse se change en entier avant que le '
                      'dernier parte, en plus du rythme : personne ne s''en occupera.'
                 WHEN t.avant_depart
                 THEN 'Quand l''appartement va se vider, à faire avant que le dernier parte, en plus du '
                      'rythme.' END,
            CASE WHEN t.au_retour_apres_jours IS NOT NULL
                 THEN format('Quand l''appartement est resté vide plus de %s jours, à refaire au retour, '
                             'pour le premier rentré, le jour même, ou le lendemain s''il rentre après '
                             '21 h.', t.au_retour_apres_jours) END,
            CASE WHEN t.utilise_machine
                 THEN 'Une seule machine par jour : jamais le même jour qu''une autre lessive.' END,
            CASE WHEN t.requiert_les_deux
                 THEN 'Se fait à deux, au même moment, sur un créneau où les deux sont libres. S''il '
                      'n''y en a aucun, le dire aux deux plutôt que de la poser au hasard.' END,
            CASE WHEN EXISTS (SELECT 1 FROM accompagnement a
                               WHERE a.journee_libre AND t.id_tache IN (a.id_tache, a.id_tache_jointe))
                 THEN 'Les jours sans cours ni travail, la poussière et le récurage se font ensemble, '
                      'l''aspirateur entre les deux : c''est le bloc « Nettoyage ». Seulement si l''un '
                      'des deux était déjà dû ce jour-là, et sans avancer l''autre de plus du tiers de '
                      'sa période.' END
        ) AS texte
          FROM tache t
         WHERE t.categorie <> 'sport'
    )
    INSERT INTO description_tache (id_tache, texte)
    SELECT p.id_tache, p.texte
      FROM phrases p
     WHERE p.texte <> ''
       AND NOT EXISTS (SELECT 1 FROM description_tache d WHERE d.id_tache = p.id_tache);
END $etape$;


-- -----------------------------------------------------------------------------
-- 4. Les cinq types de base                                    (TAC-25, TAC-26)
--
-- Le premier type de chaque famille d'origine, comme la 067 les rangeait. Ils
-- se renomment et se recolorent, ne se suppriment pas. Les autres n'ont pas de
-- base.
-- -----------------------------------------------------------------------------
ALTER TABLE type_tache ADD COLUMN IF NOT EXISTS base VARCHAR(10);

DO $etape$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.columns
                WHERE table_schema = 'public' AND table_name = 'type_tache'
                  AND column_name = 'categorie') THEN
        UPDATE type_tache y
           SET base = y.categorie
         WHERE y.id_type_tache = (SELECT z.id_type_tache FROM type_tache z
                                   WHERE z.categorie = y.categorie
                                   ORDER BY z.ordre, z.id_type_tache LIMIT 1);
    END IF;
END $etape$;

-- Un type de base supprimé avant cette version revient, sous son nom d'origine,
-- ou suffixé si un type du foyer porte déjà ce nom.
INSERT INTO type_tache (libelle, couleur, icone, duree_minutes, priorite, ordre, base)
SELECT CASE WHEN EXISTS (SELECT 1 FROM type_tache x WHERE lower(btrim(x.libelle)) = lower(v.libelle))
            THEN v.libelle || ' (base)' ELSE v.libelle END,
       v.couleur, v.icone, v.duree, v.priorite, v.ordre, v.base
  FROM (VALUES ('Ménage',        '#FFD166', 'house',      10, 4, 'menage',    1),
               ('Linge',         '#B794F6', 'tshirt',     15, 2, 'linge',     2),
               ('Vaisselle',     '#6FD3F2', 'fork.knife',  5, 2, 'vaisselle', 3),
               ('Chat',          '#FF9BCB', 'pawprint',    5, 1, 'animal',    4),
               ('Administratif', '#AEB8C8', 'doc.text',   15, 2, 'admin',     5)
       ) AS v(libelle, couleur, icone, duree, priorite, base, ordre)
 WHERE NOT EXISTS (SELECT 1 FROM type_tache t WHERE t.base = v.base);

ALTER TABLE type_tache DROP COLUMN IF EXISTS categorie CASCADE;

ALTER TABLE type_tache DROP CONSTRAINT IF EXISTS type_tache_base_connue;
ALTER TABLE type_tache ADD CONSTRAINT type_tache_base_connue
    CHECK (base IS NULL OR base IN ('menage', 'linge', 'vaisselle', 'animal', 'admin'));
CREATE UNIQUE INDEX IF NOT EXISTS type_tache_base_unique ON type_tache (base) WHERE base IS NOT NULL;

COMMENT ON COLUMN type_tache.base IS
    'TAC-25 : l''un des cinq types de base, qui ne se suppriment pas. Vide pour un type créé par le foyer. Ne change pas quand on renomme le type.';


-- -----------------------------------------------------------------------------
-- 5. La tâche : sa façon de revenir, son arrêt                  (TAC-1, TAC-30)
-- -----------------------------------------------------------------------------
ALTER TABLE tache
    ADD COLUMN IF NOT EXISTS revient    VARCHAR(12),
    ADD COLUMN IF NOT EXISTS arretee_le TIMESTAMPTZ;

DO $etape$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                    WHERE table_schema = 'public' AND table_name = 'tache'
                      AND column_name = 'categorie') THEN
        RETURN;
    END IF;

    UPDATE tache t
       SET revient = CASE
               WHEN t.categorie = 'sport' THEN NULL
               WHEN t.recurrente THEN 'rythme'
               WHEN EXISTS (SELECT 1 FROM enchainement e WHERE e.id_tache_suivante = t.id_tache) THEN 'apres'
               ELSE 'dates'
           END;

    -- La date de l'arrêt n'était pas gardée : la dernière trace de la tâche en
    -- tient lieu.
    UPDATE tache t
       SET arretee_le = COALESCE((SELECT max(COALESCE(o.date_faite, upper(o.fenetre), o.date_creation))
                                    FROM occurrence o WHERE o.id_tache = t.id_tache), now())
     WHERE NOT t.active AND t.arretee_le IS NULL;

    -- Une tâche de la maison a toujours un type, arrêtée comprise : la tâche du
    -- sport est la seule qui n'en a pas.
    UPDATE tache
       SET id_type_tache = (SELECT id_type_tache FROM type_tache WHERE base = 'menage')
     WHERE id_type_tache IS NULL AND categorie <> 'sport';

    -- Sans rythme, pas de périodicité.
    ALTER TABLE tache ALTER COLUMN periodicite_min_jours DROP NOT NULL,
                      ALTER COLUMN periodicite_max_jours DROP NOT NULL;
    UPDATE tache SET periodicite_min_jours = NULL, periodicite_max_jours = NULL
     WHERE revient IS DISTINCT FROM 'rythme';


    -- -----------------------------------------------------------------------------
    -- 6. Les colonnes qui partent                                  (TAC-29, annexe 15)
    --
    -- Les vues qui les lisaient partent avec elles ; sql/definitions/ les recrée.
    -- -----------------------------------------------------------------------------
    ALTER TABLE tache DROP CONSTRAINT IF EXISTS tache_nature_coherente;
    ALTER TABLE tache DROP CONSTRAINT IF EXISTS tache_duo_coherent;
    ALTER TABLE tache DROP CONSTRAINT IF EXISTS tache_plage_contient_la_duree;
    ALTER TABLE tache DROP CONSTRAINT IF EXISTS tache_type_hors_sport;

    ALTER TABLE tache
        DROP COLUMN IF EXISTS code                  CASCADE,
        DROP COLUMN IF EXISTS categorie             CASCADE,
        DROP COLUMN IF EXISTS rappel_journee        CASCADE,
        DROP COLUMN IF EXISTS recurrente            CASCADE,
        DROP COLUMN IF EXISTS utilise_machine       CASCADE,
        DROP COLUMN IF EXISTS requiert_les_deux     CASCADE,
        DROP COLUMN IF EXISTS reportable            CASCADE,
        DROP COLUMN IF EXISTS abandon_apres_jours   CASCADE,
        DROP COLUMN IF EXISTS avant_depart          CASCADE,
        DROP COLUMN IF EXISTS au_retour_apres_jours CASCADE,
        DROP COLUMN IF EXISTS quota_hebdomadaire    CASCADE;

    -- Ce qui se déduit se calcule : « sans heure » et « régulière » ne se règlent
    -- plus à part (TAC-2, TAC-8).
    ALTER TABLE tache
        ADD COLUMN rappel_journee BOOLEAN GENERATED ALWAYS AS (heure_min IS NULL) STORED,
        ADD COLUMN recurrente     BOOLEAN GENERATED ALWAYS AS (COALESCE(revient = 'rythme', FALSE)) STORED;

    ALTER TABLE occurrence DROP COLUMN IF EXISTS utilise_machine CASCADE;

    DELETE FROM accompagnement WHERE journee_libre;
    ALTER TABLE accompagnement
        DROP COLUMN IF EXISTS journee_libre CASCADE,
        DROP COLUMN IF EXISTS bloc          CASCADE;
END $etape$;

-- Ce qui ne lit rien d'avant se rejoue sans garde.
ALTER TABLE occurrence DROP COLUMN IF EXISTS utilise_machine CASCADE;
ALTER TABLE accompagnement DROP COLUMN IF EXISTS bloc CASCADE;


-- -----------------------------------------------------------------------------
-- 7. Les contraintes de la tâche
-- -----------------------------------------------------------------------------
ALTER TABLE tache DROP CONSTRAINT IF EXISTS tache_revient_connu;
ALTER TABLE tache ADD CONSTRAINT tache_revient_connu
    CHECK (revient IS NULL OR revient IN ('rythme', 'dates', 'apres', 'description'));
ALTER TABLE tache DROP CONSTRAINT IF EXISTS tache_rythme_coherent;
ALTER TABLE tache ADD CONSTRAINT tache_rythme_coherent
    CHECK ((revient IS NOT DISTINCT FROM 'rythme') = (periodicite_min_jours IS NOT NULL)
           AND (periodicite_min_jours IS NULL) = (periodicite_max_jours IS NULL));
-- TAC-2, TAC-23 : une plage a ses deux bornes, et contient la durée.
ALTER TABLE tache DROP CONSTRAINT IF EXISTS tache_plage_coherente;
ALTER TABLE tache ADD CONSTRAINT tache_plage_coherente
    CHECK ((heure_min IS NULL) = (heure_max IS NULL)
           AND (heure_min IS NULL OR heure_max > heure_min));
ALTER TABLE tache DROP CONSTRAINT IF EXISTS tache_plage_contient_la_duree;
ALTER TABLE tache ADD CONSTRAINT tache_plage_contient_la_duree
    CHECK (heure_min IS NULL OR heure_max - heure_min >= make_interval(mins => duree_minutes));
-- TAC-25 : la tâche du sport est la seule sans type, et elle seule ne revient
-- d'aucune des quatre façons.
ALTER TABLE tache DROP CONSTRAINT IF EXISTS tache_type_hors_sport;
ALTER TABLE tache ADD CONSTRAINT tache_type_hors_sport
    CHECK ((id_type_tache IS NULL) = (revient IS NULL));
CREATE UNIQUE INDEX IF NOT EXISTS tache_du_sport_unique ON tache ((TRUE)) WHERE id_type_tache IS NULL;
ALTER TABLE tache DROP CONSTRAINT IF EXISTS tache_arret_date;
ALTER TABLE tache ADD CONSTRAINT tache_arret_date
    CHECK (active = (arretee_le IS NULL));

-- TAC-26 : un type ne se supprime plus en laissant des tâches sans type ; ses
-- tâches arrêtées passent d'abord à Ménage.
ALTER TABLE tache DROP CONSTRAINT IF EXISTS tache_id_type_tache_fkey;
ALTER TABLE tache ADD CONSTRAINT tache_id_type_tache_fkey
    FOREIGN KEY (id_type_tache) REFERENCES type_tache (id_type_tache);

COMMENT ON COLUMN tache.revient IS
    'TAC-1 : rythme, dates, après une autre, ou selon la description (MTA-8). Vide pour la tâche du sport.';
COMMENT ON COLUMN tache.arretee_le IS
    'TAC-30 : la date de l''arrêt, que montre la liste des tâches arrêtées.';
COMMENT ON COLUMN tache.rappel_journee IS
    'TAC-2 : calculée. Sans plage horaire, la tâche est un rappel dans la journée.';
COMMENT ON COLUMN tache.recurrente IS
    'TAC-8 : calculée. Seule une tâche qui revient par un rythme est engendrée par la génération.';


-- -----------------------------------------------------------------------------
-- 8. L'occurrence : posée par HAL, épinglée par HAL                (VER-1, VER-10)
-- -----------------------------------------------------------------------------
ALTER TABLE occurrence ADD COLUMN IF NOT EXISTS epinglee_par VARCHAR(5);
UPDATE occurrence SET epinglee_par = 'admin' WHERE epinglee AND epinglee_par IS NULL;
ALTER TABLE occurrence DROP CONSTRAINT IF EXISTS occurrence_epinglee_par;
ALTER TABLE occurrence ADD CONSTRAINT occurrence_epinglee_par
    CHECK ((epinglee_par IS NOT NULL) = epinglee AND (epinglee_par IS NULL OR epinglee_par IN ('admin', 'hal')));

ALTER TABLE occurrence DROP CONSTRAINT IF EXISTS occurrence_origine_check;
ALTER TABLE occurrence ADD CONSTRAINT occurrence_origine_check
    CHECK (origine IN ('recurrence', 'manuelle', 'enchainement', 'hal', 'coach',
                       'stock', 'quota', 'depart', 'retour'));

COMMENT ON COLUMN occurrence.epinglee_par IS
    'VER-1 : qui a épinglé : l''administrateur, l''utilisateur pour une séance posée à la main, ou HAL pour ce qu''il place selon une description.';


-- -----------------------------------------------------------------------------
-- 9. La file des vérifications                                    (VER-3, VER-4)
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS verification_tache (
    id_verification BIGINT      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    id_occurrence   INTEGER     REFERENCES occurrence (id_occurrence) ON DELETE CASCADE,
    id_tache        INTEGER     REFERENCES tache (id_tache) ON DELETE CASCADE,
    raison          VARCHAR(16) NOT NULL,
    cree_le         TIMESTAMPTZ NOT NULL DEFAULT now(),
    traitee_le      TIMESTAMPTZ,
    id_appel        BIGINT      REFERENCES appel_coach (id_appel) ON DELETE SET NULL,

    CONSTRAINT verification_tache_cible CHECK ((id_occurrence IS NULL) <> (id_tache IS NULL)),
    CONSTRAINT verification_tache_raison
        CHECK (raison IN ('creee', 'deplacee', 'a_placer', 'occupation', 'absence', 'conflit',
                          'repartition', 'description'))
);

CREATE UNIQUE INDEX IF NOT EXISTS verification_occurrence_en_attente
    ON verification_tache (id_occurrence) WHERE traitee_le IS NULL AND id_occurrence IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS verification_tache_en_attente
    ON verification_tache (id_tache) WHERE traitee_le IS NULL AND id_tache IS NOT NULL;

COMMENT ON TABLE verification_tache IS
    'VER-3 : ce que HAL doit relire au prochain quart d''heure : une occurrence d''une tâche décrite, ou la tâche entière après une absence.';


-- -----------------------------------------------------------------------------
-- 10. La vérification de la semaine, et ses moments                (VER-5, VER-8)
-- -----------------------------------------------------------------------------
ALTER TABLE foyer
    ADD COLUMN IF NOT EXISTS verification_jour  SMALLINT NOT NULL DEFAULT 1,
    ADD COLUMN IF NOT EXISTS verification_heure TIME     NOT NULL DEFAULT TIME '06:30',
    -- Le dernier jour où la vérification de la semaine a eu lieu : une par semaine.
    ADD COLUMN IF NOT EXISTS semaine_relue_le   DATE;
ALTER TABLE foyer DROP CONSTRAINT IF EXISTS foyer_verification_jour;
ALTER TABLE foyer ADD CONSTRAINT foyer_verification_jour CHECK (verification_jour BETWEEN 1 AND 7);

COMMENT ON COLUMN foyer.verification_jour IS
    'VER-8 : le jour de la vérification de la semaine, 1 pour lundi. Réglé par l''administrateur du foyer.';

ALTER TABLE appel_coach DROP CONSTRAINT IF EXISTS appel_coach_moment_check;
ALTER TABLE appel_coach ADD CONSTRAINT appel_coach_moment_check
    CHECK (moment IN ('faisabilite', 'plan', 'revision', 'synthese', 'bilan', 'signalement',
                      'chat', 'changement', 'maison', 'presence', 'absent', 'soiree',
                      'meteo', 'semaine', 'verification'));

ALTER TABLE echange DROP CONSTRAINT IF EXISTS echange_moment_check;
ALTER TABLE echange ADD CONSTRAINT echange_moment_check
    CHECK (moment IN ('faisabilite', 'plan', 'revision', 'synthese', 'bilan', 'signalement',
                      'chat', 'changement', 'externe', 'maison', 'presence', 'absent',
                      'soiree', 'meteo', 'semaine', 'verification'));


-- -----------------------------------------------------------------------------
-- 11. Reprendre une tâche, un geste de plus                        (TAC-30, ACT-1)
--
-- L'effacement, lui, reste au bouton (ACT-5) : il n'a pas d'action.
-- -----------------------------------------------------------------------------
ALTER TABLE demande DROP CONSTRAINT IF EXISTS demande_action_check;
ALTER TABLE demande ADD CONSTRAINT demande_action_check
    CHECK (action IN ('tache', 'modification_tache', 'arret_tache', 'reprise_tache', 'lien',
                      'report', 'faite', 'absence', 'occupation', 'allegement', 'conflit',
                      'seance', 'valider_semaine', 'valider_seance', 'pas_faite'));

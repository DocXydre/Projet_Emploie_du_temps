-- =============================================================================
-- 049 : les tâches qui vont ensemble           (TAC-14 à TAC-19, PLA-14, ABS-8)
--
-- Rejouable.
--
-- Jusqu'ici chaque tâche se plaçait seule. Le planning proposait donc le même
-- jour un ramassage de litière et son vidage complet, un récurage sans
-- aspirateur avant, et il fallait cocher la poussière pour qu'un aspirateur
-- apparaisse le lendemain. Cette migration pose les liens qui manquaient :
--
--   ce qui en couvre une autre       le vidage vaut ramassage, dès le planning
--   ce qui en accompagne une autre   l'aspirateur avant de récurer, le même jour
--   ce qui suit                      vider le lave-vaisselle, le lendemain
--   ce qu'on fait en partant         le lave-vaisselle, la litière, les poubelles
--   ce qu'on fait en rentrant        l'eau de Sassy, après deux jours d'absence
--
-- Aucune fonction ici : elles sont dans sql/definitions/, comme tout depuis 047.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 1. Un titre propre à l'occurrence                                    (TAC-16)
--
-- « Passer l'aspirateur (avant de récurer) », « Nettoyage 2/3 : Passer
-- l'aspirateur » : le nom de la tâche ne suffit plus quand elle en accompagne
-- une autre. Le titre est recalculé à chaque placement.
-- -----------------------------------------------------------------------------
ALTER TABLE occurrence ADD COLUMN IF NOT EXISTS titre TEXT;

COMMENT ON COLUMN occurrence.titre IS
    'TAC-16 : ce qu''on affiche à la place du libellé de la tâche quand elle en
     accompagne une autre ce jour-là. Vide le reste du temps.';


-- -----------------------------------------------------------------------------
-- 2. Une occurrence peut naître d'un retour                             (ABS-8)
-- -----------------------------------------------------------------------------
ALTER TABLE occurrence DROP CONSTRAINT IF EXISTS occurrence_origine_check;
ALTER TABLE occurrence ADD CONSTRAINT occurrence_origine_check
    CHECK (origine IN ('recurrence', 'manuelle', 'enchainement', 'stock',
                       'quota', 'depart', 'retour'));

ALTER TABLE tache ADD COLUMN IF NOT EXISTS au_retour_apres_jours SMALLINT;
ALTER TABLE tache DROP CONSTRAINT IF EXISTS tache_au_retour_positif;
ALTER TABLE tache ADD CONSTRAINT tache_au_retour_positif
    CHECK (au_retour_apres_jours IS NULL OR au_retour_apres_jours > 0);

COMMENT ON COLUMN tache.au_retour_apres_jours IS
    'ABS-8 : à refaire en rentrant quand l''appartement est resté vide plus de
     ce nombre de jours. L''eau de Sassy a stagné, on la change.';


-- -----------------------------------------------------------------------------
-- 3. Ce qui accompagne                                         (TAC-15, TAC-17)
--
-- Quand `id_tache` est prévue un jour, `id_tache_jointe` vient le même jour,
-- pour la même personne. `journee_libre` réserve la règle aux jours sans cours
-- ni travail : c'est le bloc « Nettoyage », un coup de plus un jour où l'on a
-- le temps.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS accompagnement (
    id_accompagnement SERIAL      PRIMARY KEY,
    id_tache          INTEGER     NOT NULL REFERENCES tache(id_tache) ON DELETE CASCADE,
    id_tache_jointe   INTEGER     NOT NULL REFERENCES tache(id_tache) ON DELETE CASCADE,
    place             VARCHAR(5)  NOT NULL CHECK (place IN ('avant', 'apres')),
    -- « avant de récurer », « après la poussière » : ce qu'on lit à côté de la
    -- tâche jointe. Le libellé d'une tâche ne se conjugue pas tout seul.
    mention           VARCHAR(60),
    journee_libre     BOOLEAN     NOT NULL DEFAULT FALSE,
    bloc              VARCHAR(40),

    CONSTRAINT accompagnement_unique UNIQUE (id_tache, id_tache_jointe),
    CONSTRAINT accompagnement_non_reflexif CHECK (id_tache <> id_tache_jointe),
    -- Une règle de journée libre forme un bloc, et un bloc a un nom.
    CONSTRAINT accompagnement_bloc_nomme CHECK (journee_libre = (bloc IS NOT NULL))
);

COMMENT ON TABLE accompagnement IS
    'TAC-15, TAC-17 : une tâche en entraîne une autre le même jour, pour la même
     personne, avant ou après elle.';

INSERT INTO accompagnement (id_tache, id_tache_jointe, place, mention, journee_libre, bloc)
SELECT a.id_tache, b.id_tache, r.place, r.mention, r.journee_libre, r.bloc
  FROM (VALUES
        ('RECURAGE',  'ASPIRATEUR', 'avant', 'avant de récurer',    FALSE, NULL),
        ('POUSSIERE', 'ASPIRATEUR', 'apres', 'après la poussière',  FALSE, NULL),
        ('RECURAGE',  'POUSSIERE',  'avant', NULL,                  TRUE,  'Nettoyage'),
        ('POUSSIERE', 'RECURAGE',   'apres', NULL,                  TRUE,  'Nettoyage')
       ) AS r(tache, jointe, place, mention, journee_libre, bloc)
  JOIN tache a ON a.code = r.tache
  JOIN tache b ON b.code = r.jointe
ON CONFLICT (id_tache, id_tache_jointe) DO NOTHING;

-- L'ancien lien créait l'aspirateur après coup, une fois la poussière ou le
-- récurage cochés. Pour le récurage c'était à l'envers, et dans les deux cas
-- l'aspirateur n'apparaissait au planning qu'au dernier moment.
DELETE FROM enchainement e
 USING tache src, tache cible
 WHERE src.id_tache = e.id_tache_source
   AND cible.id_tache = e.id_tache_suivante
   AND src.code IN ('POUSSIERE', 'RECURAGE')
   AND cible.code = 'ASPIRATEUR';


-- -----------------------------------------------------------------------------
-- 4. Vider le lave-vaisselle                                           (TAC-14)
--
-- On le lance le soir, il se vide dans la journée qui suit. Pas de récurrence
-- propre : la tâche naît de la validation du lancement, comme le linge à
-- étendre naît de la lessive.
-- -----------------------------------------------------------------------------
INSERT INTO tache (code, libelle, categorie, priorite, duree_minutes,
                   periodicite_min_jours, periodicite_max_jours,
                   rappel_journee, reportable, recurrente)
VALUES ('VIDER_LAVE_VAISSELLE', 'Vider le lave-vaisselle', 'vaisselle', 2, 5,
        1, 1, TRUE, TRUE, FALSE)
ON CONFLICT (code) DO NOTHING;

-- Huit heures : le temps du cycle et de la nuit. Vingt : lancé à 22 heures, il
-- se vide le lendemain, pas le surlendemain.
INSERT INTO enchainement (id_tache_source, id_tache_suivante, delai_min_heures, delai_max_heures)
SELECT src.id_tache, cible.id_tache, 8, 20
  FROM tache src
  JOIN tache cible ON cible.code = 'VIDER_LAVE_VAISSELLE'
 WHERE src.code = 'LAVE_VAISSELLE'
ON CONFLICT (id_tache_source, id_tache_suivante) DO NOTHING;


-- -----------------------------------------------------------------------------
-- 5. En partant, en rentrant                                    (TAC-18, ABS-8)
--
-- Quand l'appartement se vide : les poubelles, le lave-vaisselle lancé, et la
-- caisse de Sassy changée en entier. Le vidage remplace le simple ramassage,
-- qui n'a plus à figurer dans la liste.
-- -----------------------------------------------------------------------------
UPDATE tache SET avant_depart = TRUE
 WHERE code IN ('POUBELLES', 'LAVE_VAISSELLE', 'LITIERE_VIDAGE');
UPDATE tache SET avant_depart = FALSE WHERE code = 'LITIERE_CROTTES';

UPDATE tache SET au_retour_apres_jours = 2 WHERE code = 'EAU_SASSY';


-- -----------------------------------------------------------------------------
-- 6. Les priorités                                                     (PLA-14)
--
-- 1 passe en premier quand deux tâches veulent la même place. Du linge mouillé
-- n'attend pas. Le récurage, qui emmène son aspirateur, se place avant lui.
-- -----------------------------------------------------------------------------
UPDATE tache SET priorite = 1 WHERE code = 'ETENDRE_LINGE';
UPDATE tache SET priorite = 3 WHERE code = 'RECURAGE';

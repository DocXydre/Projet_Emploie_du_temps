-- =============================================================================
-- Scénario de vérification
--
--   ./sql/appliquer.sh --recreer && docker exec -i planif-db psql -U planif -d planif -f - < sql/999_scenario_test.sql
--
-- Ce fichier n'est jamais appliqué automatiquement : il n'est pas numéroté
-- comme une migration. Il déroule une semaine type et vérifie que le système
-- se comporte comme le cahier des charges le décrit.
-- =============================================================================

\set ON_ERROR_STOP on
\timing off

BEGIN;

-- ---- Comptes de test ---------------------------------------------------------
INSERT INTO utilisateur (pseudo, nom, role, cle_api) VALUES
    ('thomas',  'Thomas',  'admin',    repeat('t', 40)),
    ('lorette', 'Lorette', 'standard', repeat('l', 40));

UPDATE tache SET id_utilisateur_defaut = (SELECT id_utilisateur FROM utilisateur WHERE pseudo='thomas');
UPDATE tache SET id_utilisateur_defaut = (SELECT id_utilisateur FROM utilisateur WHERE pseudo='lorette')
 WHERE code = 'PLIER_LINGE';

\echo '=== 1. Contraintes dures : cours et shifts ==='

-- Une semaine type : cours en journée, shifts le soir.
INSERT INTO occupation (id_utilisateur, id_source, type, libelle, periode, cle_externe)
SELECT u.id_utilisateur, s.id_source, 'cours', 'Cours IDMC',
       tstzrange(debut_jour(jour_de(now()) + j) + INTERVAL '8 hours',
                 debut_jour(jour_de(now()) + j) + INTERVAL '12 hours', '[)'),
       'cours-' || j
  FROM utilisateur u, source s, generate_series(1, 5) j
 WHERE u.pseudo = 'thomas' AND s.code = 'MANUELLE';

INSERT INTO occupation (id_utilisateur, id_source, type, libelle, periode, cle_externe)
SELECT u.id_utilisateur, s.id_source, 'travail', 'Shift McDonald''s',
       tstzrange(debut_jour(jour_de(now()) + j) + INTERVAL '17 hours',
                 debut_jour(jour_de(now()) + j) + INTERVAL '23 hours', '[)'),
       'shift-' || j
  FROM utilisateur u, source s, generate_series(1, 4) j
 WHERE u.pseudo = 'thomas' AND s.code = 'MANUELLE';

-- Sommeil, pour que le moteur ne place rien à 4h du matin.
INSERT INTO occupation (id_utilisateur, id_source, type, libelle, periode, cle_externe)
SELECT u.id_utilisateur, s.id_source, 'sommeil', 'Sommeil',
       tstzrange(debut_jour(jour_de(now()) + j) - INTERVAL '1 hour',
                 debut_jour(jour_de(now()) + j) + INTERVAL '7 hours', '[)'),
       'sommeil-' || j
  FROM utilisateur u, source s, generate_series(0, 21) j
 WHERE u.pseudo = 'thomas' AND s.code = 'MANUELLE';

\echo '--- R3 : deux shifts qui se chevauchent doivent être refusés ---'
DO $$
BEGIN
    INSERT INTO occupation (id_utilisateur, id_source, type, libelle, periode)
    SELECT u.id_utilisateur, s.id_source, 'travail', 'Shift en double',
           tstzrange(debut_jour(jour_de(now()) + 1) + INTERVAL '18 hours',
                     debut_jour(jour_de(now()) + 1) + INTERVAL '20 hours', '[)')
      FROM utilisateur u, source s WHERE u.pseudo='thomas' AND s.code='MANUELLE';
    RAISE EXCEPTION 'ÉCHEC : le chevauchement aurait dû être refusé';
EXCEPTION WHEN exclusion_violation THEN
    RAISE NOTICE 'OK : chevauchement de shifts refusé par la base';
END $$;


\echo ''
\echo '=== 2. Placement ==='

SELECT placer_taches(21) AS taches_placees;

\echo '--- planning des 3 prochains jours ---'
SELECT to_char(debut AT TIME ZONE 'Europe/Paris', 'DD/MM HH24:MI') AS debut,
       CASE WHEN journee_entiere THEN 'journée' ELSE to_char(fin AT TIME ZONE 'Europe/Paris', 'HH24:MI') END AS fin,
       nature, libelle
  FROM v_planning
 WHERE debut < now() + INTERVAL '3 days'
 ORDER BY debut, journee_entiere;

\echo '--- R11 : aucune tâche à heure imposée ne se chevauche ---'
SELECT count(*) AS chevauchements_interdits
  FROM occurrence a JOIN occurrence b
    ON a.id_occurrence < b.id_occurrence
   AND a.id_utilisateur = b.id_utilisateur
   AND a.creneau && b.creneau
 WHERE NOT a.rappel_journee AND NOT b.rappel_journee
   AND a.statut IN ('planifiee','notifiee') AND b.statut IN ('planifiee','notifiee');

\echo '--- R35 : jamais deux machines le même jour ---'
SELECT jour_de(lower(creneau)) AS jour, count(*) AS machines
  FROM occurrence WHERE utilise_machine AND creneau IS NOT NULL
 GROUP BY 1 HAVING count(*) > 1;

\echo '--- R17 : les machines sont bien placées en heures creuses ---'
SELECT t.code, to_char(lower(o.creneau) AT TIME ZONE 'Europe/Paris', 'DD/MM HH24:MI') AS lancement
  FROM occurrence o JOIN tache t USING (id_tache)
 WHERE t.utilise_machine AND o.creneau IS NOT NULL ORDER BY o.creneau;


\echo ''
\echo '=== 3. Validation, récurrence et enchaînement ==='

\echo '--- avant : occurrences de POUSSIERE et ASPIRATEUR ---'
SELECT tache_code, statut, to_char(echeance_min AT TIME ZONE 'Europe/Paris','DD/MM') AS du,
       to_char(echeance_max AT TIME ZONE 'Europe/Paris','DD/MM') AS au
  FROM v_occurrence WHERE tache_code IN ('POUSSIERE','ASPIRATEUR') ORDER BY tache_code;

SELECT valider_occurrence(
           (SELECT id_occurrence FROM v_occurrence WHERE tache_code='POUSSIERE' AND statut <> 'faite' LIMIT 1),
           (SELECT id_utilisateur FROM utilisateur WHERE pseudo='thomas')
       ) AS poussiere_validee;

\echo '--- après : la suivante part de la date réelle, l''aspirateur est repositionné ---'
SELECT tache_code, statut, origine, motif,
       to_char(echeance_min AT TIME ZONE 'Europe/Paris','DD/MM HH24:MI') AS du,
       to_char(echeance_max AT TIME ZONE 'Europe/Paris','DD/MM HH24:MI') AS au
  FROM v_occurrence WHERE tache_code IN ('POUSSIERE','ASPIRATEUR') ORDER BY tache_code, id_occurrence;

\echo '--- R25 : revalider doit être refusé ---'
DO $$
DECLARE v_id INTEGER;
BEGIN
    SELECT id_occurrence INTO v_id FROM occurrence WHERE statut='faite' LIMIT 1;
    UPDATE occurrence SET statut='faite', date_faite=now() WHERE id_occurrence=v_id;
    RAISE EXCEPTION 'ÉCHEC : la revalidation aurait dû être refusée';
EXCEPTION WHEN check_violation THEN
    RAISE NOTICE 'OK : revalidation refusée';
END $$;

\echo '--- R21 : valider dans le futur doit être refusé ---'
DO $$
DECLARE v_id INTEGER;
BEGIN
    SELECT id_occurrence INTO v_id FROM occurrence WHERE statut='a_placer' LIMIT 1;
    UPDATE occurrence SET statut='faite', date_faite=now() + INTERVAL '1 day' WHERE id_occurrence=v_id;
    RAISE EXCEPTION 'ÉCHEC : la validation dans le futur aurait dû être refusée';
EXCEPTION WHEN check_violation THEN
    RAISE NOTICE 'OK : validation dans le futur refusée';
END $$;


\echo ''
\echo '=== 4. Stock d''uniforme et lessive ==='

\echo '--- stock initial ---'
SELECT code, quantite_propre, quantite_utilisable, seuil_securite, jours_de_travail_couverts FROM v_stock ORDER BY code;

\echo '--- on salit deux t-shirts : il ne reste plus qu''une unité au-dessus du seuil ---'
INSERT INTO mouvement_stock (id_article, type, quantite)
SELECT id_article, 'salissure', 2 FROM article_travail WHERE code='TSHIRT';

SELECT code, quantite_propre, quantite_utilisable FROM v_stock ORDER BY code;

\echo '--- projection : quand tombe la rupture, et quelle échéance pour la lessive ---'
SELECT article, jour_rupture,
       to_char(echeance_lessive AT TIME ZONE 'Europe/Paris', 'DD/MM HH24:MI') AS lessive_avant,
       alerte
  FROM projeter_stock((SELECT id_utilisateur FROM utilisateur WHERE pseudo='thomas'));

SELECT declencher_lessive((SELECT id_utilisateur FROM utilisateur WHERE pseudo='thomas')) AS lessives_creees;

\echo '--- R34 : échéance déjà dépassée pour les t-shirts, une alerte doit exister ---'
SELECT type, statut, contenu FROM notification;

SELECT tache_code, statut, origine, motif,
       to_char(echeance_max AT TIME ZONE 'Europe/Paris','DD/MM HH24:MI') AS avant_le
  FROM v_occurrence WHERE tache_code='LESSIVE_TRAVAIL';

\echo '--- validation de la lessive : le linge n''est pas portable tout de suite ---'
SELECT placer_taches(21) AS replacement;

SELECT valider_occurrence(
           (SELECT id_occurrence FROM occurrence o JOIN tache t USING (id_tache)
             WHERE t.code='LESSIVE_TRAVAIL' AND o.statut <> 'faite' LIMIT 1),
           (SELECT id_utilisateur FROM utilisateur WHERE pseudo='thomas')
       ) AS lessive_validee;

SELECT code, quantite_propre, quantite_utilisable, en_sechage,
       to_char(disponible_le AT TIME ZONE 'Europe/Paris','DD/MM HH24:MI') AS portable_a_partir_de
  FROM v_stock ORDER BY code;


\echo ''
\echo '=== 5. Grand nettoyage : intersection de disponibilités ==='

-- Lorette a cours tous les après-midis de la semaine : les seuls moments où
-- ils sont libres tous les deux sont le week-end.
INSERT INTO occupation (id_utilisateur, id_source, type, libelle, periode, cle_externe)
SELECT u.id_utilisateur, s.id_source, 'cours', 'Cours de Lorette',
       tstzrange(debut_jour(jour_de(now()) + j) + INTERVAL '13 hours',
                 debut_jour(jour_de(now()) + j) + INTERVAL '19 hours', '[)'),
       'lorette-' || j
  FROM utilisateur u, source s, generate_series(0, 30) j
 WHERE u.pseudo = 'lorette' AND s.code = 'MANUELLE'
   AND EXTRACT(ISODOW FROM debut_jour(jour_de(now()) + j)) <= 5;

SELECT placer_taches(31) AS replacement;

\echo '--- le grand nettoyage doit tomber un samedi ou un dimanche ---'
SELECT to_char(lower(o.creneau) AT TIME ZONE 'Europe/Paris', 'TMDay DD/MM HH24:MI') AS creneau,
       to_char(upper(o.creneau) AT TIME ZONE 'Europe/Paris', 'HH24:MI') AS fin,
       o.statut, o.motif
  FROM occurrence o JOIN tache t USING (id_tache)
 WHERE t.code = 'GRAND_NETTOYAGE';

\echo '--- vérification : les deux sont bien libres sur ce créneau ---'
SELECT u.pseudo,
       NOT EXISTS (SELECT 1 FROM occupation oc
                    WHERE oc.id_utilisateur = u.id_utilisateur
                      AND oc.periode && (SELECT creneau FROM occurrence o
                                          JOIN tache t USING (id_tache)
                                         WHERE t.code='GRAND_NETTOYAGE')) AS libre
  FROM utilisateur u ORDER BY u.pseudo;

\echo '--- si Lorette n''est jamais libre, le système alerte au lieu de placer ---'
INSERT INTO occupation (id_utilisateur, id_source, type, libelle, periode, cle_externe)
SELECT u.id_utilisateur, s.id_source, 'autre', 'Absente tout le mois',
       tstzrange(debut_jour(jour_de(now())), debut_jour(jour_de(now()) + 40), '[)'),
       'absence-longue'
  FROM utilisateur u, source s
 WHERE u.pseudo = 'lorette' AND s.code = 'MANUELLE';

UPDATE occurrence SET creneau = NULL, statut = 'a_placer'
 WHERE id_tache = (SELECT id_tache FROM tache WHERE code='GRAND_NETTOYAGE');

SELECT placer_taches(31) AS replacement;

SELECT o.statut, o.motif FROM occurrence o JOIN tache t USING (id_tache)
 WHERE t.code = 'GRAND_NETTOYAGE';

SELECT type, contenu FROM notification WHERE contenu LIKE '%nettoyage%';


\echo ''
\echo '=== 6. Report d''office ==='

-- On simule une tâche du jour non faite en la datant d'hier.
UPDATE occurrence
   SET creneau = tstzrange(debut_jour(jour_de(now()) - 1), debut_jour(jour_de(now())), '[)'),
       fenetre = tstzrange(debut_jour(jour_de(now()) - 2), debut_jour(jour_de(now())), '[)'),
       statut  = 'notifiee'
 WHERE id_occurrence = (SELECT id_occurrence FROM occurrence o JOIN tache t USING (id_tache)
                         WHERE t.code = 'ASPIRATEUR' AND o.statut IN ('a_placer','planifiee') LIMIT 1);

SELECT reporter_taches_du_jour() AS reportees;

SELECT tache_code, statut, nb_relances, en_retard, jours_de_retard, motif
  FROM v_occurrence WHERE tache_code='ASPIRATEUR' AND statut <> 'faite';

ROLLBACK;

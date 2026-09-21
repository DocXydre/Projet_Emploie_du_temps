-- rejouable : IF EXISTS partout, CREATE OR REPLACE, et des UPDATE gardés.
-- -----------------------------------------------------------------------------
-- 031 — Retrait du stock d'uniforme
--
-- Le stock de vêtements de travail n'existait que pour le planning McDonald's :
-- compter les services, salir les t-shirts, prévoir la lessive avant la
-- rupture. Plus de travail en uniforme, plus rien à compter.
--
-- Le code retiré est conservé dans anciennes_fonctionnalites/stock_uniforme/,
-- avec de quoi le remettre en service. Les données, elles, ne sont pas
-- effacées : les deux tables passent dans le schéma « archive », hors de la
-- vue de l'application.
--
-- Ce qui reste : la lessive de blanc, l'étendage et le pliage, et la règle
-- UNI-12 qui interdit deux machines le même jour. Elles ne doivent rien au
-- stock.
-- -----------------------------------------------------------------------------


-- 1. La lessive de travail s'arrête. Désactivée plutôt que supprimée : ses
--    occurrences passées font partie de l'historique.
UPDATE occurrence
   SET statut = 'abandonnee',
       motif  = 'Fonctionnalité retirée : stock d''uniforme'
 WHERE id_tache IN (SELECT id_tache FROM tache WHERE code = 'LESSIVE_TRAVAIL')
   AND statut IN ('a_placer', 'planifiee', 'notifiee');

UPDATE tache SET active = FALSE WHERE code = 'LESSIVE_TRAVAIL' AND active;


-- 2. Le placement ne consulte plus le stock avant de placer.
CREATE OR REPLACE FUNCTION public.placer_taches(p_horizon_jours integer DEFAULT 35, p_stabilite_jours integer DEFAULT 7)
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
    PERFORM generer_seances_sport(p_horizon_jours);

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
       AND (creneau IS NULL
            OR lower(creneau) > v_gele
            OR (id_utilisateur IS NOT NULL
                AND est_absent(id_utilisateur, jour_de(lower(creneau)))));

    FOR o IN
        SELECT oc.id_occurrence, oc.id_tache, oc.id_utilisateur, oc.fenetre,
               oc.rappel_journee, oc.utilise_machine,
               t.duree_minutes, t.heure_min, t.heure_max,
               t.requiert_les_deux, t.libelle, t.categorie
          FROM occurrence oc
          JOIN tache t ON t.id_tache = oc.id_tache
         WHERE oc.statut = 'a_placer'
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

        IF o.categorie = 'sport' THEN
            -- Le sport a ses propres contraintes : heures d'ouverture d'un
            -- lieu, trajet aller-retour, repos avant la prochaine obligation.
            -- La fonction vit dans `013_sport.sql`, avec les tables qu'elle
            -- interroge ; plpgsql ne les résout qu'à l'exécution, et rien
            -- n'appelle ce placement entre les deux migrations.
            SELECT s.creneau, s.lieu_retenu INTO v_creneau, v_lieu
              FROM chercher_creneau_sport(v_assigne, o.id_tache, o.fenetre, v_duree) s;
        ELSIF o.rappel_journee THEN
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


-- 3. Valider une lessive ne met plus rien à sécher (ancienne UNI-13).
CREATE OR REPLACE FUNCTION public.trg_occurrence_apres_validation()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
DECLARE
    t          RECORD;
    e          RECORD;
    v_cible    RECORD;
    v_depart   TIMESTAMPTZ;
    v_limite   TIMESTAMPTZ;
    v_existante INTEGER;
BEGIN
    SELECT * INTO t FROM tache WHERE id_tache = NEW.id_tache;

    -- ---- Les prévisions deviennent fausses ----------------------------------
    --
    -- Les occurrences pré-générées étaient calculées en supposant la tâche
    -- faite en fin de fenêtre. La validation donne la vraie date : on efface
    -- les suivantes et on les régénère. Une prévision jamais annoncée n'a pas
    -- à laisser de trace.
    DELETE FROM occurrence
     WHERE id_tache = NEW.id_tache
       AND id_occurrence <> NEW.id_occurrence
       AND origine = 'recurrence'
       AND statut IN ('a_placer', 'planifiee')
       AND NOT epinglee;

    -- ---- EXE-1 : l'occurrence suivante part de la date réelle ------------------
    IF t.active AND t.recurrente THEN
        INSERT INTO occurrence (id_tache, id_utilisateur, fenetre, origine,
                                id_occurrence_source)
        VALUES (t.id_tache,
                t.id_utilisateur_defaut,
                fenetre_pour(t.rappel_journee,
                             NEW.date_faite + make_interval(days => t.periodicite_min_jours),
                             NEW.date_faite + make_interval(days => t.periodicite_max_jours)),
                'recurrence',
                NEW.id_occurrence);
    END IF;

    -- ---- EXE-2, EXE-3 : enchaînements, sans doublon et jamais avant la source ----
    FOR e IN SELECT * FROM enchainement WHERE id_tache_source = NEW.id_tache LOOP

        SELECT * INTO v_cible FROM tache WHERE id_tache = e.id_tache_suivante;
        CONTINUE WHEN NOT v_cible.active;

        -- Le délai minimum décale le début de la fenêtre : le linge étendu ce
        -- soir ne se plie pas dans la foulée, mais le lendemain.
        v_depart := NEW.date_faite + make_interval(hours => e.delai_min_heures);
        v_limite := NEW.date_faite + make_interval(hours => e.delai_max_heures);

        SELECT id_occurrence INTO v_existante
          FROM occurrence
         WHERE id_tache = e.id_tache_suivante
           AND statut IN ('a_placer', 'planifiee', 'notifiee')
           AND fenetre && tstzrange(v_depart, v_limite, '[)')
         ORDER BY upper(fenetre)
         LIMIT 1;

        IF v_existante IS NOT NULL THEN
            -- Anti-doublon : on repositionne au lieu de créer une deuxième
            -- occurrence de la même tâche.
            UPDATE occurrence
               SET fenetre = fenetre_pour(v_cible.rappel_journee, v_depart, v_limite),
                   creneau = NULL,
                   statut  = 'a_placer',
                   motif   = format('Repositionnée après %s', t.code)
             WHERE id_occurrence = v_existante;
        ELSE
            INSERT INTO occurrence (id_tache, id_utilisateur, fenetre, origine,
                                    id_occurrence_source, motif)
            VALUES (v_cible.id_tache,
                    v_cible.id_utilisateur_defaut,
                    fenetre_pour(v_cible.rappel_journee, v_depart, v_limite),
                    'enchainement',
                    NEW.id_occurrence,
                    format('Déclenchée par %s', t.code));
        END IF;
    END LOOP;

    -- ---- TAC-10 : faire ceci vaut avoir fait cela ------------------------------
    --
    -- L'occurrence couverte est marquée faite à la même date. Ce trigger se
    -- redéclenche alors pour elle, ce qui recrée sa suivante au bon moment :
    -- vider la litière un mardi repousse le prochain ramassage au jeudi.
    FOR e IN SELECT id_tache_couverte FROM remplacement WHERE id_tache_faite = NEW.id_tache LOOP
        UPDATE occurrence
           SET statut     = 'faite',
               date_faite = NEW.date_faite,
               motif      = format('Couverte par %s', t.code)
         WHERE id_tache = e.id_tache_couverte
           AND statut IN ('a_placer', 'planifiee', 'notifiee');
    END LOOP;

    RETURN NULL;
END $function$;


-- 4. Les fonctions et la vue du stock.
DROP FUNCTION IF EXISTS declencher_lessive(INTEGER);
DROP FUNCTION IF EXISTS projeter_stock(INTEGER);
DROP FUNCTION IF EXISTS rattraper_uniforme(INTEGER);
DROP FUNCTION IF EXISTS consommer_uniforme(DATE);
DROP FUNCTION IF EXISTS recaler_uniforme(VARCHAR, INTEGER);
DROP VIEW     IF EXISTS v_stock;

-- CASCADE emporte les deux triggers de mouvement_stock, et eux seuls.
DROP FUNCTION IF EXISTS trg_mouvement_appliquer() CASCADE;
DROP FUNCTION IF EXISTS trg_mouvement_compteur()  CASCADE;


-- 5. Les données partent en archive. Le lien vers les occurrences est coupé :
--    l'archive ne doit rien retenir, ni rien bloquer, dans le schéma vivant.
CREATE SCHEMA IF NOT EXISTS archive;

COMMENT ON SCHEMA archive IS
    'Données des fonctionnalités retirées. Hors du chemin de recherche : rien
     dans l''application ne les lit. Voir anciennes_fonctionnalites/.';

ALTER TABLE IF EXISTS mouvement_stock SET SCHEMA archive;
ALTER TABLE IF EXISTS article_travail SET SCHEMA archive;

ALTER TABLE IF EXISTS archive.mouvement_stock
    DROP CONSTRAINT IF EXISTS mouvement_stock_id_occurrence_fkey;


-- 6. Plus de tâche qui « lave l'uniforme ». utilise_machine reste : la
--    lessive de blanc et UNI-12 en ont besoin.
ALTER TABLE tache DROP CONSTRAINT IF EXISTS tache_lavage_coherent;
ALTER TABLE tache DROP COLUMN     IF EXISTS lave_uniforme;

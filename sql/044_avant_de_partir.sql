-- rejouable : ALTER ... IF NOT EXISTS, CREATE OR REPLACE, et des mises à jour
--             idempotentes. Le nettoyage des occurrences de poubelles ne porte
--             que sur celles qui ont gardé l'ancienne forme.
-- =============================================================================
-- 044 : ce qu'on fait avant de partir                        (TAC-12, TAC-13)
--
-- Trois choses que le premier vrai voyage a mises au jour.
--
-- Les poubelles ont une heure. On ne sort pas un sac à 9h du matin : le
-- ramassage passe au petit jour, et le sac attendrait dehors toute la journée.
-- C'est entre 17h et minuit, et pas ailleurs.
--
-- Et surtout, il y a des tâches qui ne peuvent pas attendre le retour. Un
-- appartement vide deux jours avec un sac plein sent le sac plein. Pareil pour
-- la litière : le chat reste, lui. Ces deux-là se posent donc avant le départ,
-- le dernier soir possible, et seulement quand personne ne reste.
--
-- Enfin, une proposition de week-end devient un week-end dès qu'une absence la
-- couvre. Elle le devenait déjà en base, mais rien ne le déclenchait au moment
-- où le billet créait l'absence, et le calendrier continuait à poser la
-- question.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 1. Une tâche qui se fait avant de partir                             (TAC-12)
-- -----------------------------------------------------------------------------
ALTER TABLE tache ADD COLUMN IF NOT EXISTS avant_depart BOOLEAN NOT NULL DEFAULT FALSE;

COMMENT ON COLUMN tache.avant_depart IS
    'Vrai pour ce qui ne peut pas attendre le retour quand l''appartement se
     vide : les poubelles, la litière. Une occurrence est alors créée avant le
     départ, en plus de la récurrence ordinaire (TAC-12).';

ALTER TABLE occurrence DROP CONSTRAINT IF EXISTS occurrence_origine_check;
ALTER TABLE occurrence ADD CONSTRAINT occurrence_origine_check
    CHECK (origine IN ('recurrence', 'manuelle', 'enchainement', 'stock',
                       'quota', 'depart'));


-- -----------------------------------------------------------------------------
-- 2. Les poubelles ont une heure                                       (TAC-13)
--
-- 17h le soir, minuit au plus tard. La collecte passe avant l'aube et le sac
-- peut rester dehors jusque-là ; rien n'oblige à le sortir à 3h du matin, donc
-- la borne haute s'arrête à la fin de la journée.
-- -----------------------------------------------------------------------------
-- La périodicité s'ouvre d'un jour au passage. Une tâche à heure imposée dont
-- les deux bornes sont identiques n'a pas de fenêtre du tout : « le quatrième
-- jour, à la seconde près » ne se place nulle part. Sortir le sac le troisième
-- soir reste correct, le quatrième est la limite.
UPDATE tache
   SET rappel_journee        = FALSE,
       heure_min             = TIME '17:00',
       heure_max             = TIME '23:59',
       periodicite_min_jours = 3,
       periodicite_max_jours = 4,
       avant_depart          = TRUE
 WHERE code = 'POUBELLES'
   AND rappel_journee;

UPDATE tache SET avant_depart = TRUE WHERE code = 'LITIERE_CROTTES';

-- Les occurrences déjà générées gardent la nature qu'elles avaient à leur
-- création : celles des poubelles se croient encore des rappels de journée. On
-- efface celles qui n'ont pas eu lieu, la génération les refera.
DELETE FROM occurrence
 WHERE id_tache = (SELECT id_tache FROM tache WHERE code = 'POUBELLES')
   AND statut IN ('a_placer', 'planifiee', 'notifiee')
   AND rappel_journee;


-- -----------------------------------------------------------------------------
-- 3. Quand l'appartement se vide                                       (TAC-12)
--
-- L'intersection des absences de tout le monde. Si une seule personne reste,
-- il n'y a pas de fenêtre : c'est elle qui sortira le sac, et le placement
-- ordinaire s'en charge.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fenetres_appartement_vide(p_horizon_jours INTEGER DEFAULT 35)
RETURNS SETOF TSTZRANGE LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_horizon TSTZRANGE;
    v_commun  TSTZMULTIRANGE;
    v_sienne  TSTZMULTIRANGE;
    u         RECORD;
BEGIN
    v_horizon := tstzrange(now(), now() + make_interval(days => p_horizon_jours), '[)');

    FOR u IN SELECT id_utilisateur FROM utilisateur WHERE actif LOOP
        SELECT COALESCE(range_agg(a.periode), '{}'::TSTZMULTIRANGE) INTO v_sienne
          FROM absence a
         WHERE a.id_utilisateur = u.id_utilisateur
           AND a.periode && v_horizon;

        -- Quelqu'un reste : inutile de continuer, l'appartement ne se vide pas.
        IF v_sienne = '{}'::TSTZMULTIRANGE THEN
            RETURN;
        END IF;

        v_commun := CASE WHEN v_commun IS NULL THEN v_sienne
                         ELSE v_commun * v_sienne END;
    END LOOP;

    IF v_commun IS NULL THEN
        RETURN;
    END IF;

    RETURN QUERY SELECT r FROM unnest(v_commun * multirange(v_horizon)) r;
END $$;

COMMENT ON FUNCTION fenetres_appartement_vide IS
    'Les périodes où personne n''est là : l''intersection des absences de tous
     les comptes actifs (TAC-12).';


-- -----------------------------------------------------------------------------
-- 4. Poser ce qui doit être fait avant de partir                       (TAC-12)
--
-- Une occurrence par tâche et par départ, dont la fenêtre se termine à l'heure
-- du train. Le placement ordinaire la case ensuite, en respectant les heures de
-- la tâche : le dernier soir possible pour les poubelles, la journée du départ
-- pour la litière.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION taches_avant_depart(p_horizon_jours INTEGER DEFAULT 35)
RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE
    f        TSTZRANGE;
    t        RECORD;
    v_depart TIMESTAMPTZ;
    v_heure  TIME;
    v_jour   DATE;
    v_debut  TIMESTAMPTZ;
    v_creees INTEGER := 0;
BEGIN
    -- Un départ qui a bougé laisse une occurrence qui ne veut plus rien dire.
    DELETE FROM occurrence o
     WHERE o.origine = 'depart'
       AND o.statut IN ('a_placer', 'planifiee')
       AND upper(o.fenetre) > now()
       AND NOT EXISTS (SELECT 1 FROM fenetres_appartement_vide(p_horizon_jours) g
                        WHERE o.fenetre && tstzrange(lower(g) - INTERVAL '24 hours',
                                                     lower(g), '[)'));

    FOR f IN SELECT * FROM fenetres_appartement_vide(p_horizon_jours) LOOP
        v_depart := lower(f);
        CONTINUE WHEN v_depart <= now();

        FOR t IN SELECT * FROM tache WHERE active AND avant_depart ORDER BY priorite LOOP

            -- Déjà faite ou déjà prévue dans la journée qui précède : le sac
            -- est sorti, on n'en redemande pas un second.
            CONTINUE WHEN EXISTS (
                SELECT 1 FROM occurrence o
                 WHERE o.id_tache = t.id_tache
                   AND ((o.statut = 'faite'
                         AND o.date_faite > v_depart - INTERVAL '20 hours')
                     OR (o.statut IN ('planifiee', 'notifiee')
                         AND o.creneau IS NOT NULL
                         AND lower(o.creneau) > v_depart - INTERVAL '20 hours'
                         AND lower(o.creneau) <= v_depart)
                     OR (o.origine = 'depart'
                         AND o.statut <> 'abandonnee'
                         AND o.fenetre && tstzrange(v_depart - INTERVAL '24 hours',
                                                    v_depart, '[)'))));

            v_heure := (v_depart AT TIME ZONE 'Europe/Paris')::TIME;

            IF t.rappel_journee THEN
                -- Un départ à l'aube ne laisse pas le temps de faire quoi que
                -- ce soit : c'est la veille.
                v_jour  := jour_de(v_depart) - (v_heure < TIME '09:00')::INTEGER;
                v_debut := debut_jour(v_jour);
            ELSE
                -- Le dernier soir possible : celui du départ s'il part assez
                -- tard pour que la tâche y tienne, sinon la veille.
                v_jour  := jour_de(v_depart)
                           - (v_heure < t.heure_min
                                        + make_interval(mins => t.duree_minutes))::INTEGER;
                v_debut := (v_jour + t.heure_min) AT TIME ZONE 'Europe/Paris';
            END IF;

            CONTINUE WHEN v_debut >= v_depart;

            -- TAC-5 : un rappel de journée se pose sur la journée entière, et
            -- sa fenêtre doit pouvoir la contenir. Elle déborde donc l'heure du
            -- train, mais le motif, lui, dit bien avant quoi.
            INSERT INTO occurrence (id_tache, fenetre, origine, motif)
            VALUES (t.id_tache,
                    fenetre_pour(t.rappel_journee, v_debut,
                                 v_depart - INTERVAL '1 second'),
                    'depart',
                    format('Avant de partir le %s : l''appartement sera vide',
                           to_char(v_depart AT TIME ZONE 'Europe/Paris',
                                   'DD/MM à HH24hMI')));

            v_creees := v_creees + 1;
        END LOOP;
    END LOOP;

    RETURN v_creees;
END $$;

COMMENT ON FUNCTION taches_avant_depart IS
    'Crée, avant chaque départ qui vide l''appartement, une occurrence des
     tâches qui ne peuvent pas attendre le retour (TAC-12).';


-- -----------------------------------------------------------------------------
-- 5. Le placement enchaîne les trois                            (TAC-12, WKD-3)
--
-- Corps repris tel quel de la migration 033, avec deux appels en tête. Le
-- reste est inchangé : la fonction est longue, mais la recopier entière évite
-- de deviner ce qu'une réécriture partielle aurait emporté.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION placer_taches(p_horizon_jours integer DEFAULT 35, p_stabilite_jours integer DEFAULT 7)
 RETURNS integer
 LANGUAGE plpgsql
AS $$
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

    -- WKD-3 : une absence vaut réponse à une proposition de week-end. Sans cet
    -- appel, la proposition restait au calendrier alors que le billet était
    -- acheté et l'absence déclarée.
    PERFORM entretenir_propositions();

    -- TAC-12 : ce qui ne peut pas attendre qu'on rentre. L'appel vient avant le
    -- placement, pour que les occurrences créées ici soient placées dans la
    -- foulée.
    PERFORM taches_avant_depart(p_horizon_jours);

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
END $$;


-- -----------------------------------------------------------------------------
-- 6. Un week-end proposé devient un week-end                           (WKD-6)
--
-- Tant qu'elle attend une réponse, la proposition pose une question. Une fois
-- le billet acheté, elle n'a plus à la poser : elle devient le week-end, et
-- reste au calendrier pour qu'on voie où l'on est.
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
-- qu'on y pense, et cesse de poser la question dès qu'on a répondu.
-- WKD-6 : une fois le voyage confirmé, elle reste, sans point d'interrogation
-- et sans préfixe « Proposition ».
SELECT
    'proposition'                      AS nature,
    p.id_proposition                   AS id,
    p.id_utilisateur,
    CASE WHEN p.statut = 'realisee' THEN 'weekend' ELSE 'trajet' END AS categorie,
    CASE WHEN p.statut = 'realisee'
         THEN 'Week-end' || COALESCE(' à ' || p.lieu, '')
         ELSE 'Week-end libre' || COALESCE(' à ' || p.lieu, '') || ' ?'
    END                                AS libelle,
    p.periode,
    lower(p.periode)                   AS debut,
    upper(p.periode)                   AS fin,
    TRUE                               AS journee_entiere,
    p.statut,
    p.lieu,
    CASE WHEN p.statut = 'realisee'
         THEN 'Confirmé : une absence couvre ce week-end'
         ELSE 'Repéré par le système : aucune obligation sur cette période'
    END                                AS motif,
    0                                  AS nb_relances
FROM proposition p
WHERE p.statut IN ('proposee', 'realisee');

COMMENT ON VIEW v_planning IS
    'Occupations, tâches placées et propositions dans une seule vue. Le drapeau
     journee_entiere décide si l''export produit un VEVENT horaire ou un
     VEVENT journée entière (NOT-3). Une réservation de sport s''y lit « à
     déterminer », sans lieu (SPT-18). Une proposition réalisée s''y lit
     « Week-end à ... », sans question (WKD-6).';

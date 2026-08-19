-- =============================================================================
-- 003 : fonctions
--
-- Le calcul des disponibilités, la génération des occurrences, la projection du
-- stock et le placement vivent ici. L'API se contente de les appeler.
--
-- Le fuseau d'affichage est Europe/Paris : c'est lui qui définit ce qu'est
-- « une journée ». Le stockage reste en UTC.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- Bornes d'une journée civile française, en UTC
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION debut_jour(p_jour DATE)
RETURNS TIMESTAMPTZ LANGUAGE sql STABLE AS $$
    SELECT (p_jour::TIMESTAMP) AT TIME ZONE 'Europe/Paris';
$$;

CREATE OR REPLACE FUNCTION jour_de(p_instant TIMESTAMPTZ)
RETURNS DATE LANGUAGE sql STABLE AS $$
    SELECT (p_instant AT TIME ZONE 'Europe/Paris')::DATE;
$$;


-- -----------------------------------------------------------------------------
-- Fenêtre d'échéance d'une occurrence
--
-- Pour un rappel, la fenêtre est alignée sur des journées entières : c'est ce
-- qui permet ensuite au créneau « journée entière » d'y être inclus (R10).
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fenetre_pour(
    p_rappel_journee BOOLEAN,
    p_debut          TIMESTAMPTZ,
    p_fin            TIMESTAMPTZ
) RETURNS TSTZRANGE LANGUAGE sql STABLE AS $$
    SELECT CASE
        WHEN p_rappel_journee THEN
            tstzrange(debut_jour(jour_de(p_debut)),
                      debut_jour(jour_de(p_fin) + 1),
                      '[)')
        ELSE
            tstzrange(p_debut, p_fin, '[)')
    END;
$$;


-- -----------------------------------------------------------------------------
-- Disponibilités : l'horizon moins les occupations, moins les créneaux placés
--                                                                        (R16)
--
-- Les multirange de PostgreSQL font tout le travail : on agrège tout ce qui est
-- occupé en un seul multirange, et on le soustrait de l'horizon. Pas de boucle,
-- pas de découpage manuel.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION disponibilites(
    p_utilisateur INTEGER,
    p_debut       TIMESTAMPTZ,
    p_fin         TIMESTAMPTZ
) RETURNS SETOF TSTZRANGE LANGUAGE sql STABLE AS $$
    WITH occupe AS (
        SELECT o.periode AS plage
          FROM occupation o
         WHERE o.id_utilisateur = p_utilisateur
           AND o.periode && tstzrange(p_debut, p_fin, '[)')

        UNION ALL

        -- Les rappels ne réservent pas d'heure précise : ils ne bloquent pas
        -- le calendrier, seulement le volume horaire de la journée.
        SELECT o.creneau
          FROM occurrence o
         WHERE o.id_utilisateur = p_utilisateur
           AND o.creneau IS NOT NULL
           AND NOT o.rappel_journee
           AND o.statut IN ('planifiee', 'notifiee')
           AND o.creneau && tstzrange(p_debut, p_fin, '[)')
    )
    SELECT unnest(
        tstzmultirange(tstzrange(p_debut, p_fin, '[)'))
        - COALESCE((SELECT range_agg(plage) FROM occupe), '{}'::TSTZMULTIRANGE)
    );
$$;


CREATE OR REPLACE FUNCTION temps_libre_jour(p_utilisateur INTEGER, p_jour DATE)
RETURNS INTERVAL LANGUAGE sql STABLE AS $$
    SELECT COALESCE(sum(upper(d) - lower(d)), INTERVAL '0')
      FROM disponibilites(p_utilisateur, debut_jour(p_jour), debut_jour(p_jour + 1)) d;
$$;


-- -----------------------------------------------------------------------------
-- La machine à laver est une ressource unique de l'appartement           (R35)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION machine_occupee(p_jour DATE, p_sauf INTEGER DEFAULT NULL)
RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
    SELECT EXISTS (
        SELECT 1 FROM occurrence o
         WHERE o.utilise_machine
           AND o.creneau IS NOT NULL
           AND o.statut IN ('planifiee', 'notifiee')
           AND jour_de(lower(o.creneau)) = p_jour
           AND (p_sauf IS NULL OR o.id_occurrence <> p_sauf)
    );
$$;


-- -----------------------------------------------------------------------------
-- Recherche d'un créneau horaire, pour une tâche à heure imposée         (R17)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION chercher_creneau(
    p_utilisateur INTEGER,
    p_fenetre     TSTZRANGE,
    p_duree       INTERVAL,
    p_heure_min   TIME,
    p_heure_max   TIME,
    p_machine     BOOLEAN
) RETURNS TSTZRANGE LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_jour    DATE;
    v_dernier DATE;
    v_plage   TSTZRANGE;
    v_dispo   TSTZRANGE;
BEGIN
    v_jour    := GREATEST(jour_de(lower(p_fenetre)), jour_de(now()));
    v_dernier := jour_de(upper(p_fenetre) - INTERVAL '1 second');

    WHILE v_jour <= v_dernier LOOP
        IF NOT (p_machine AND machine_occupee(v_jour)) THEN

            -- Plage autorisée ce jour-là, ramenée à la fenêtre d'échéance.
            v_plage := tstzrange(
                           (v_jour + p_heure_min) AT TIME ZONE 'Europe/Paris',
                           (v_jour + p_heure_max) AT TIME ZONE 'Europe/Paris',
                           '[)')
                       * p_fenetre;

            IF NOT isempty(v_plage) THEN
                FOR v_dispo IN
                    SELECT d FROM disponibilites(p_utilisateur, lower(v_plage), upper(v_plage)) d
                     ORDER BY lower(d)
                LOOP
                    IF upper(v_dispo) - lower(v_dispo) >= p_duree THEN
                        RETURN tstzrange(lower(v_dispo), lower(v_dispo) + p_duree, '[)');
                    END IF;
                END LOOP;
            END IF;
        END IF;

        v_jour := v_jour + 1;
    END LOOP;

    RETURN NULL;
END $$;


-- -----------------------------------------------------------------------------
-- Recherche d'un jour, pour un rappel sans heure imposée                 (R18)
--
-- On ne cherche pas un créneau mais une journée qui laisse assez de temps
-- libre au total, une fois déduits les autres rappels déjà posés ce jour-là.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION chercher_jour(
    p_utilisateur INTEGER,
    p_fenetre     TSTZRANGE,
    p_duree       INTERVAL
) RETURNS TSTZRANGE LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_jour    DATE;
    v_dernier DATE;
    v_deja    INTEGER;
    v_libre   INTERVAL;
BEGIN
    v_jour    := GREATEST(jour_de(lower(p_fenetre)), jour_de(now()));
    v_dernier := jour_de(upper(p_fenetre) - INTERVAL '1 second');

    WHILE v_jour <= v_dernier LOOP
        SELECT COALESCE(sum(t.duree_minutes), 0) INTO v_deja
          FROM occurrence o
          JOIN tache t ON t.id_tache = o.id_tache
         WHERE o.id_utilisateur = p_utilisateur
           AND o.rappel_journee
           AND o.creneau IS NOT NULL
           AND o.statut IN ('planifiee', 'notifiee')
           AND jour_de(lower(o.creneau)) = v_jour;

        v_libre := temps_libre_jour(p_utilisateur, v_jour) - make_interval(mins => v_deja);

        IF v_libre >= p_duree THEN
            RETURN tstzrange(debut_jour(v_jour), debut_jour(v_jour + 1), '[)');
        END IF;

        v_jour := v_jour + 1;
    END LOOP;

    RETURN NULL;
END $$;


-- -----------------------------------------------------------------------------
-- Génération des occurrences manquantes                          (opération 2)
--
-- Une tâche qui a déjà une occurrence en cours est ignorée : c'est ce qui
-- empêche l'accumulation.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION generer_occurrences() RETURNS INTEGER
LANGUAGE plpgsql AS $$
DECLARE
    t       RECORD;
    v_ref   TIMESTAMPTZ;
    v_debut TIMESTAMPTZ;
    v_fin   TIMESTAMPTZ;
    v_creees INTEGER := 0;
BEGIN
    FOR t IN SELECT * FROM tache WHERE active ORDER BY priorite LOOP

        CONTINUE WHEN EXISTS (
            SELECT 1 FROM occurrence
             WHERE id_tache = t.id_tache
               AND statut IN ('a_placer', 'planifiee', 'notifiee')
        );

        -- R21 : la référence est la dernière exécution réelle, jamais la date
        -- théorique. Une tâche faite en retard ne décale pas tout le planning.
        SELECT max(date_faite) INTO v_ref
          FROM occurrence
         WHERE id_tache = t.id_tache AND statut = 'faite';

        IF v_ref IS NULL THEN
            -- Jamais faite : elle est due dès aujourd'hui.
            v_debut := now();
            v_fin   := now() + make_interval(days => t.periodicite_max_jours);
        ELSE
            v_debut := v_ref + make_interval(days => t.periodicite_min_jours);
            v_fin   := v_ref + make_interval(days => t.periodicite_max_jours);
        END IF;

        INSERT INTO occurrence (id_tache, id_utilisateur, fenetre, origine)
        VALUES (t.id_tache,
                t.id_utilisateur_defaut,
                fenetre_pour(t.rappel_journee, v_debut, v_fin),
                'recurrence');

        v_creees := v_creees + 1;
    END LOOP;

    RETURN v_creees;
END $$;


-- -----------------------------------------------------------------------------
-- Projection du stock de vêtements de travail                    (opération 3)
--
-- On déroule les journées de travail à venir en décrémentant le stock, et on
-- s'arrête à la première qui passerait sous le seuil de sécurité.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION projeter_stock(p_utilisateur INTEGER)
RETURNS TABLE (
    article          VARCHAR,
    jour_rupture     DATE,
    echeance_lessive TIMESTAMPTZ,
    alerte           BOOLEAN
) LANGUAGE plpgsql STABLE AS $$
DECLARE
    a               RECORD;
    j               RECORD;
    v_jours_couverts NUMERIC;
    v_duree_cycle   INTERVAL := INTERVAL '2 hours';
BEGIN
    FOR a IN SELECT * FROM v_stock LOOP

        -- Journées de travail couvertes sans jamais entamer le seuil.
        v_jours_couverts := GREATEST(a.quantite_utilisable - a.seuil_securite, 0)
                            * a.jours_par_unite;

        FOR j IN
            SELECT * FROM v_journees_travail
             WHERE id_utilisateur = p_utilisateur
             ORDER BY jour
        LOOP
            IF v_jours_couverts < 1 THEN
                article          := a.code;
                jour_rupture     := j.jour;
                -- R33 : il faut que le linge soit lavé, puis sec, avant le shift.
                echeance_lessive := j.debut_premier_shift
                                    - make_interval(hours => a.heures_sechage)
                                    - v_duree_cycle;
                alerte           := echeance_lessive <= now();
                RETURN NEXT;
                EXIT;
            END IF;

            v_jours_couverts := v_jours_couverts - 1;
        END LOOP;
    END LOOP;
END $$;


-- -----------------------------------------------------------------------------
-- Déclenchement de la lessive de travail                     (R33, R34)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION declencher_lessive(p_utilisateur INTEGER) RETURNS INTEGER
LANGUAGE plpgsql AS $$
DECLARE
    v_tache    RECORD;
    v_echeance TIMESTAMPTZ;
    v_alerte   BOOLEAN;
BEGIN
    SELECT * INTO v_tache FROM tache WHERE lave_uniforme AND active LIMIT 1;
    IF NOT FOUND THEN
        RETURN 0;
    END IF;

    -- L'article le plus contraignant impose l'échéance.
    SELECT min(echeance_lessive), bool_or(alerte)
      INTO v_echeance, v_alerte
      FROM projeter_stock(p_utilisateur);

    IF v_echeance IS NULL THEN
        RETURN 0;   -- le stock tient sur tous les shifts connus
    END IF;

    -- R34 : trop tard pour que le linge sèche. On alerte au lieu de planifier
    -- une tâche qui ne résoudrait rien.
    --
    -- Ce contrôle vient avant celui de l'occurrence existante : sinon une
    -- lessive déjà prévue mais devenue intenable ferait taire l'alerte, ce qui
    -- est exactement le cas où l'on a le plus besoin d'être prévenu.
    IF v_echeance <= now() THEN
        INSERT INTO notification (id_utilisateur, type, contenu)
        SELECT p_utilisateur, 'alerte',
               'Stock d''uniforme critique : même lancée maintenant, la lessive '
               || 'ne sera pas sèche pour le prochain shift.'
        WHERE NOT EXISTS (
            SELECT 1 FROM notification
             WHERE id_utilisateur = p_utilisateur
               AND type = 'alerte'
               AND statut = 'a_envoyer'
               AND date_creation > now() - INTERVAL '12 hours'
        );
        RETURN 0;
    END IF;

    -- Déjà prévue : on resserre son échéance si le stock s'est dégradé. Si un
    -- créneau était placé au-delà de la nouvelle échéance, il est libéré pour
    -- que le placement suivant en trouve un plus tôt.
    IF EXISTS (SELECT 1 FROM occurrence
                WHERE id_tache = v_tache.id_tache
                  AND statut IN ('a_placer', 'planifiee', 'notifiee')) THEN

        UPDATE occurrence
           SET creneau = CASE WHEN creneau IS NOT NULL AND upper(creneau) > v_echeance
                              THEN NULL ELSE creneau END,
               statut  = CASE WHEN creneau IS NOT NULL AND upper(creneau) > v_echeance
                              THEN 'a_placer' ELSE statut END,
               fenetre = tstzrange(LEAST(lower(fenetre), v_echeance - INTERVAL '1 hour'),
                                   v_echeance, '[)'),
               motif   = 'Échéance resserrée : stock d''uniforme en baisse'
         WHERE id_tache = v_tache.id_tache
           AND statut IN ('a_placer', 'planifiee', 'notifiee')
           AND upper(fenetre) > v_echeance;

        RETURN 0;
    END IF;

    INSERT INTO occurrence (id_tache, id_utilisateur, fenetre, origine, motif)
    VALUES (v_tache.id_tache,
            p_utilisateur,
            tstzrange(now(), v_echeance, '[)'),
            'stock',
            'Stock d''uniforme sous le seuil de sécurité');

    RETURN 1;
END $$;


-- -----------------------------------------------------------------------------
-- Placement                                                     (opération 4)
--
-- Algorithme glouton : on trie par priorité, puis par échéance, puis par durée
-- décroissante, et on prend la première place qui convient.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION placer_taches(p_horizon_jours INTEGER DEFAULT 21)
RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE
    o         RECORD;
    u         RECORD;
    v_creneau TSTZRANGE;
    v_duree   INTERVAL;
    v_places  INTEGER := 0;
BEGIN
    PERFORM generer_occurrences();

    FOR u IN SELECT id_utilisateur FROM utilisateur WHERE actif LOOP
        PERFORM declencher_lessive(u.id_utilisateur);
    END LOOP;

    -- R19 : un créneau notifié ou épinglé ne bouge plus. Sans cette règle, le
    -- planning change tous les matins et devient inutilisable.
    UPDATE occurrence
       SET creneau = NULL, statut = 'a_placer', motif = NULL
     WHERE statut = 'planifiee' AND NOT epinglee;

    FOR o IN
        SELECT oc.id_occurrence, oc.id_utilisateur, oc.fenetre, oc.rappel_journee,
               oc.utilise_machine, t.duree_minutes, t.heure_min, t.heure_max
          FROM occurrence oc
          JOIN tache t ON t.id_tache = oc.id_tache
         WHERE oc.statut = 'a_placer'
           AND upper(oc.fenetre) > now()
           AND lower(oc.fenetre) < now() + make_interval(days => p_horizon_jours)
         ORDER BY t.priorite, upper(oc.fenetre), t.duree_minutes DESC
    LOOP
        IF o.id_utilisateur IS NULL THEN
            UPDATE occurrence
               SET motif = 'Non assignée : à attribuer avant de pouvoir être placée'
             WHERE id_occurrence = o.id_occurrence;
            CONTINUE;
        END IF;

        v_duree := make_interval(mins => o.duree_minutes);

        IF o.rappel_journee THEN
            v_creneau := chercher_jour(o.id_utilisateur, o.fenetre, v_duree);
        ELSE
            v_creneau := chercher_creneau(o.id_utilisateur, o.fenetre, v_duree,
                                          o.heure_min, o.heure_max, o.utilise_machine);
        END IF;

        -- R20 : une occurrence non plaçable n'est jamais supprimée. Elle garde
        -- son statut et reçoit un motif lisible.
        IF v_creneau IS NULL THEN
            UPDATE occurrence
               SET motif = format('Aucune place de %s min avant le %s',
                                  o.duree_minutes,
                                  to_char(upper(o.fenetre) AT TIME ZONE 'Europe/Paris', 'DD/MM'))
             WHERE id_occurrence = o.id_occurrence;
        ELSE
            UPDATE occurrence
               SET creneau = v_creneau,
                   statut  = 'planifiee',
                   motif   = CASE
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
-- Validation                                                    (opération 5)
--
-- La suite — occurrence suivante, enchaînements, stock — est prise en charge
-- par les triggers de 004.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION valider_occurrence(
    p_occurrence  INTEGER,
    p_acteur      INTEGER,
    p_date_reelle TIMESTAMPTZ DEFAULT NULL
) RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE
    o      RECORD;
    v_role VARCHAR;
BEGIN
    SELECT * INTO o FROM occurrence WHERE id_occurrence = p_occurrence FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Occurrence % introuvable', p_occurrence
              USING ERRCODE = 'no_data_found';
    END IF;

    SELECT role INTO v_role FROM utilisateur WHERE id_utilisateur = p_acteur;

    -- Une tâche assignée n'est validée que par son assigné, ou par
    -- l'administrateur en dépannage.
    IF o.id_utilisateur IS NOT NULL
       AND o.id_utilisateur <> p_acteur
       AND v_role IS DISTINCT FROM 'admin' THEN
        RAISE EXCEPTION 'Cette tâche est assignée à un autre utilisateur'
              USING ERRCODE = 'insufficient_privilege';
    END IF;

    UPDATE occurrence
       SET statut     = 'faite',
           date_faite = COALESCE(p_date_reelle, now())
     WHERE id_occurrence = p_occurrence;

    RETURN p_occurrence;
END $$;


-- -----------------------------------------------------------------------------
-- Report d'office du soir                                        (opération 8)
--
-- L'occurrence n'est pas recréée : elle glisse au lendemain et son compteur de
-- relances augmente. C'est ce qui permet de dire « en retard depuis 3 jours »
-- plutôt que de laisser une chaîne d'occurrences abandonnées (R26).
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION reporter_taches_du_jour() RETURNS INTEGER
LANGUAGE plpgsql AS $$
DECLARE
    o          RECORD;
    v_reportees INTEGER := 0;
    v_demain    DATE := jour_de(now()) + 1;
BEGIN
    FOR o IN
        SELECT oc.id_occurrence, oc.creneau, oc.fenetre, oc.rappel_journee, t.reportable, t.libelle
          FROM occurrence oc
          JOIN tache t ON t.id_tache = oc.id_tache
         WHERE oc.statut IN ('planifiee', 'notifiee')
           AND oc.creneau IS NOT NULL
           AND upper(oc.creneau) <= now()
    LOOP
        -- Une lessive de travail en retard ne se reporte pas : le report ne
        -- résout rien, il faut le savoir tout de suite.
        IF NOT o.reportable THEN
            INSERT INTO notification (id_utilisateur, id_occurrence, type, contenu)
            SELECT oc.id_utilisateur, oc.id_occurrence, 'alerte',
                   format('%s non faite et non reportable.', o.libelle)
              FROM occurrence oc WHERE oc.id_occurrence = o.id_occurrence;
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

    RETURN v_reportees;
END $$;

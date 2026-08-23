-- rejouable : ce fichier ne contient que des CREATE OR REPLACE ou des IF NOT
--             EXISTS. Le rejouer après modification est sans effet de bord.
-- =============================================================================
-- 003 : fonctions
--
-- Disponibilités, génération des occurrences, projection du stock et
-- placement. L'API se contente de les appeler.
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
-- qui permet ensuite au créneau « journée entière » d'y être inclus (TAC-5).
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
--                                                                        (PLA-1)
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
-- Disponibilités communes à tous les utilisateurs actifs                 (PLA-9)
--
-- Le grand nettoyage se fait à deux : il ne suffit pas que Thomas soit libre,
-- il faut que Lorette le soit au même moment. On intersecte donc les
-- disponibilités de chacun, multirange par multirange.
--
-- L'intersection est vide dès qu'une seule personne est occupée : on sort de
-- la boucle sans interroger les suivantes.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION disponibilites_communes(
    p_debut TIMESTAMPTZ,
    p_fin   TIMESTAMPTZ
) RETURNS SETOF TSTZRANGE LANGUAGE plpgsql STABLE AS $$
DECLARE
    u        RECORD;
    v_commun TSTZMULTIRANGE := tstzmultirange(tstzrange(p_debut, p_fin, '[)'));
    v_perso  TSTZMULTIRANGE;
BEGIN
    FOR u IN SELECT id_utilisateur FROM utilisateur WHERE actif ORDER BY id_utilisateur LOOP

        SELECT COALESCE(range_agg(d), '{}'::TSTZMULTIRANGE) INTO v_perso
          FROM disponibilites(u.id_utilisateur, p_debut, p_fin) d;

        v_commun := v_commun * v_perso;

        EXIT WHEN v_commun = '{}'::TSTZMULTIRANGE;
    END LOOP;

    RETURN QUERY SELECT unnest(v_commun);
END $$;


-- Aiguillage : disponibilités d'une personne, ou de tout le monde.
CREATE OR REPLACE FUNCTION disponibilites_pour(
    p_utilisateur INTEGER,
    p_commun      BOOLEAN,
    p_debut       TIMESTAMPTZ,
    p_fin         TIMESTAMPTZ
) RETURNS SETOF TSTZRANGE LANGUAGE plpgsql STABLE AS $$
BEGIN
    IF p_commun THEN
        RETURN QUERY SELECT * FROM disponibilites_communes(p_debut, p_fin);
    ELSE
        RETURN QUERY SELECT * FROM disponibilites(p_utilisateur, p_debut, p_fin);
    END IF;
END $$;


-- -----------------------------------------------------------------------------
-- Présence dans l'appartement                                     (ABS-1, ABS-2)
--
-- On ne compte absent qu'un jour entièrement couvert par une absence. Partir
-- vendredi soir laisse la journée de vendredi utilisable : la tâche peut être
-- faite avant le départ, et la geler reviendrait à créer un retard fictif.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION est_absent(p_utilisateur INTEGER, p_jour DATE)
RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
    SELECT EXISTS (
        SELECT 1 FROM absence
         WHERE id_utilisateur = p_utilisateur
           AND periode @> tstzrange(debut_jour(p_jour), debut_jour(p_jour + 1), '[)')
    );
$$;


CREATE OR REPLACE FUNCTION presents_le(p_jour DATE)
RETURNS INTEGER[] LANGUAGE sql STABLE AS $$
    SELECT COALESCE(array_agg(id_utilisateur ORDER BY id_utilisateur), ARRAY[]::INTEGER[])
      FROM utilisateur
     WHERE actif AND NOT est_absent(id_utilisateur, p_jour);
$$;


CREATE OR REPLACE FUNCTION appartement_vide(p_jour DATE)
RETURNS BOOLEAN LANGUAGE sql STABLE AS $$
    SELECT cardinality(presents_le(p_jour)) = 0;
$$;


-- -----------------------------------------------------------------------------
-- La machine à laver est une ressource unique de l'appartement           (UNI-12)
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
-- Recherche d'un créneau horaire, pour une tâche à heure imposée         (PLA-2)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION chercher_creneau(
    p_utilisateur INTEGER,
    p_fenetre     TSTZRANGE,
    p_duree       INTERVAL,
    p_heure_min   TIME,
    p_heure_max   TIME,
    p_machine     BOOLEAN,
    p_commun      BOOLEAN DEFAULT FALSE
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
        -- ABS-1 : ni machine ni ménage un jour où l'on n'est pas là.
        IF NOT est_absent(p_utilisateur, v_jour)
           AND NOT (p_machine AND machine_occupee(v_jour)) THEN

            -- Plage autorisée ce jour-là, ramenée à la fenêtre d'échéance et
            -- à ce qui reste à venir : on ne propose pas 14h quand il est 16h.
            v_plage := tstzrange(
                           (v_jour + p_heure_min) AT TIME ZONE 'Europe/Paris',
                           (v_jour + p_heure_max) AT TIME ZONE 'Europe/Paris',
                           '[)')
                       * p_fenetre
                       * tstzrange(now(), NULL, '[)');

            IF NOT isempty(v_plage) THEN
                FOR v_dispo IN
                    SELECT d FROM disponibilites_pour(p_utilisateur, p_commun,
                                                      lower(v_plage), upper(v_plage)) d
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
-- Recherche d'un jour, pour un rappel sans heure imposée            (PLA-3, PLA-4)
--
-- On cherche une journée assez libre, pas un créneau précis.
--
-- Et le jour le moins chargé de la fenêtre, pas le premier venu : prendre le
-- premier entassait toutes les tâches sur la même journée.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION chercher_jour(
    p_utilisateur INTEGER,
    p_fenetre     TSTZRANGE,
    p_duree       INTERVAL
) RETURNS TSTZRANGE LANGUAGE plpgsql STABLE AS $$
DECLARE
    -- Au-delà, l'examen de chaque jour coûte plus qu'il ne rapporte : une tâche
    -- mensuelle n'a pas besoin d'être comparée sur trente et un jours.
    EXAMEN_MAX CONSTANT INTEGER := 21;

    v_jour       DATE;
    v_dernier    DATE;
    v_deja       INTEGER;
    v_libre      INTERVAL;
    v_meilleur   DATE     := NULL;
    v_charge_min INTEGER  := NULL;
    v_libre_max  INTERVAL := NULL;
BEGIN
    v_jour    := GREATEST(jour_de(lower(p_fenetre)), jour_de(now()));
    v_dernier := LEAST(jour_de(upper(p_fenetre) - INTERVAL '1 second'),
                       v_jour + EXAMEN_MAX);

    WHILE v_jour <= v_dernier LOOP
        -- ABS-1 : un jour d'absence ne reçoit rien. On ne fait pas le ménage
        -- d'un appartement où l'on n'est pas.
        IF est_absent(p_utilisateur, v_jour) THEN
            v_jour := v_jour + 1;
            CONTINUE;
        END IF;

        SELECT COALESCE(sum(t.duree_minutes), 0) INTO v_deja
          FROM occurrence o
          JOIN tache t ON t.id_tache = o.id_tache
         WHERE o.id_utilisateur = p_utilisateur
           AND o.rappel_journee
           AND o.creneau IS NOT NULL
           AND o.statut IN ('planifiee', 'notifiee')
           AND jour_de(lower(o.creneau)) = v_jour;

        v_libre := temps_libre_jour(p_utilisateur, v_jour) - make_interval(mins => v_deja);

        -- Deux critères, dans cet ordre : d'abord le moins de tâches déjà
        -- posées, ensuite le plus de temps libre. Le second compte autant que
        -- le premier — sans lui, une journée occupée de 1h à 23h paraîtrait
        -- idéale du seul fait qu'aucune tâche n'y est encore prévue.
        IF v_libre >= p_duree
           AND (v_charge_min IS NULL
                OR v_deja < v_charge_min
                OR (v_deja = v_charge_min AND v_libre > v_libre_max)) THEN
            v_meilleur   := v_jour;
            v_charge_min := v_deja;
            v_libre_max  := v_libre;
        END IF;

        v_jour := v_jour + 1;
    END LOOP;

    IF v_meilleur IS NULL THEN
        RETURN NULL;
    END IF;

    RETURN tstzrange(debut_jour(v_meilleur), debut_jour(v_meilleur + 1), '[)');
END $$;


-- -----------------------------------------------------------------------------
-- Génération des occurrences manquantes                          (opération 2)
--
-- Une tâche qui a déjà une occurrence en cours est ignorée : c'est ce qui
-- empêche l'accumulation.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION generer_occurrences(p_horizon_jours INTEGER DEFAULT 35)
RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE
    -- Garde-fou : une tâche quotidienne sur un horizon d'un an ferait boucler
    -- longtemps. Aucune configuration raisonnable n'atteint cette limite.
    ITERATIONS_MAX CONSTANT INTEGER := 60;

    t         RECORD;
    v_curseur TIMESTAMPTZ;
    v_fenetre TSTZRANGE;
    v_limite  TIMESTAMPTZ;
    v_tours   INTEGER;
    v_creees  INTEGER := 0;
BEGIN
    v_limite := now() + make_interval(days => p_horizon_jours);

    -- TAC-8 : les tâches non récurrentes n'apparaissent que par enchaînement.
    -- Sans ce filtre, « étendre le linge » reviendrait tous les jours, même
    -- les semaines où aucune machine ne tourne.
    FOR t IN SELECT * FROM tache WHERE active AND recurrente ORDER BY priorite LOOP

        -- Où en est cette tâche ? Trois cas, du plus précis au plus flou.
        SELECT max(upper(fenetre)) INTO v_curseur
          FROM occurrence
         WHERE id_tache = t.id_tache
           AND statut IN ('a_placer', 'planifiee', 'notifiee');

        IF v_curseur IS NULL THEN
            -- EXE-1 : la référence est la dernière exécution réelle, jamais la
            -- date théorique. Une tâche faite en retard ne décale pas tout.
            SELECT max(date_faite) INTO v_curseur
              FROM occurrence
             WHERE id_tache = t.id_tache AND statut = 'faite';

            IF v_curseur IS NULL THEN
                -- Jamais faite : elle est due dès aujourd'hui.
                v_fenetre := fenetre_pour(
                    t.rappel_journee, now(),
                    now() + make_interval(days => t.periodicite_max_jours));

                INSERT INTO occurrence (id_tache, id_utilisateur, fenetre, origine)
                VALUES (t.id_tache, t.id_utilisateur_defaut, v_fenetre, 'recurrence');

                v_creees  := v_creees + 1;
                v_curseur := upper(v_fenetre);
            END IF;
        END IF;

        -- Prolonger la chaîne jusqu'à l'horizon. Ces occurrences sont des
        -- prévisions : elles seront effacées et refaites dès qu'une validation
        -- réelle donnera une meilleure référence.
        v_tours := 0;
        WHILE v_curseur < v_limite AND v_tours < ITERATIONS_MAX LOOP
            v_fenetre := fenetre_pour(
                t.rappel_journee,
                v_curseur + make_interval(days => t.periodicite_min_jours),
                v_curseur + make_interval(days => t.periodicite_max_jours));

            INSERT INTO occurrence (id_tache, id_utilisateur, fenetre, origine)
            VALUES (t.id_tache, t.id_utilisateur_defaut, v_fenetre, 'recurrence');

            v_creees  := v_creees + 1;
            v_curseur := upper(v_fenetre);
            v_tours   := v_tours + 1;
        END LOOP;
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
                -- UNI-10 : il faut que le linge soit lavé, puis sec, avant le shift.
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
-- Déclenchement de la lessive de travail                     (UNI-10, UNI-11)
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

    -- UNI-11 : trop tard pour que le linge sèche. On alerte au lieu de planifier
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
-- À qui revient une tâche                                         (ABS-2, ABS-3)
--
-- Une tâche dont l'assignation est fixée garde son assigné, absence ou pas :
-- le pliage du linge revient à Lorette même quand Thomas est là.
--
-- Pour les autres, c'est celui qui est présent qui s'en charge. Si les deux le
-- sont, celle ou celui qui en a le moins : la répartition se mesure en minutes,
-- pas en nombre de tâches, sinon récurer vaudrait ramasser la litière.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION choisir_assigne(p_tache INTEGER, p_fenetre TSTZRANGE)
RETURNS INTEGER LANGUAGE plpgsql STABLE AS $$
DECLARE
    t            RECORD;
    u            RECORD;
    v_jour       DATE;
    v_dernier    DATE;
    v_disponible BOOLEAN;
    v_charge     INTEGER;
    v_meilleur   INTEGER := NULL;
    v_charge_min INTEGER := NULL;
BEGIN
    SELECT * INTO t FROM tache WHERE id_tache = p_tache;

    IF t.id_utilisateur_defaut IS NOT NULL THEN
        RETURN t.id_utilisateur_defaut;
    END IF;

    v_dernier := jour_de(upper(p_fenetre) - INTERVAL '1 second');

    FOR u IN SELECT id_utilisateur FROM utilisateur WHERE actif ORDER BY id_utilisateur LOOP

        -- Présent au moins un jour de la fenêtre ?
        v_disponible := FALSE;
        v_jour := GREATEST(jour_de(lower(p_fenetre)), jour_de(now()));
        WHILE v_jour <= v_dernier AND NOT v_disponible LOOP
            v_disponible := NOT est_absent(u.id_utilisateur, v_jour);
            v_jour := v_jour + 1;
        END LOOP;

        CONTINUE WHEN NOT v_disponible;

        -- PLA-10 : seules les tâches domestiques entrent dans la balance. Le
        -- sport est personnel : le compter reviendrait à faire payer ses
        -- séances de piscine en heures de ménage, et à donner l'appartement
        -- entier à l'autre.
        SELECT COALESCE(sum(t2.duree_minutes), 0) INTO v_charge
          FROM occurrence o
          JOIN tache t2 ON t2.id_tache = o.id_tache
         WHERE o.id_utilisateur = u.id_utilisateur
           AND t2.categorie <> 'sport'
           AND o.statut IN ('a_placer', 'planifiee', 'notifiee');

        IF v_charge_min IS NULL OR v_charge < v_charge_min THEN
            v_meilleur   := u.id_utilisateur;
            v_charge_min := v_charge;
        END IF;
    END LOOP;

    RETURN v_meilleur;   -- NULL si l'appartement est vide toute la fenêtre
END $$;


-- -----------------------------------------------------------------------------
-- Placement                                                     (opération 4)
--
-- Algorithme glouton : on trie par priorité, puis par échéance, puis par durée
-- décroissante, et on prend la première place qui convient.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION placer_taches(p_horizon_jours INTEGER DEFAULT 35,
                                         p_stabilite_jours INTEGER DEFAULT 7)
RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE
    o         RECORD;
    u         RECORD;
    v_creneau TSTZRANGE;
    v_duree   INTERVAL;
    v_places  INTEGER := 0;
    v_gele    TIMESTAMPTZ;
    v_assigne INTEGER;
    v_lieu    INTEGER;
BEGIN
    PERFORM generer_occurrences(p_horizon_jours);
    PERFORM generer_seances_sport(p_horizon_jours);

    FOR u IN SELECT id_utilisateur FROM utilisateur WHERE actif ORDER BY id_utilisateur LOOP
        PERFORM declencher_lessive(u.id_utilisateur);
    END LOOP;

    -- PLA-5, PLA-6 : un créneau notifié, épinglé, ou prévu dans les prochains jours
    -- ne bouge plus. Un planning qui change tous les matins ne sert à rien :
    -- on ne peut pas s'organiser autour de quelque chose qui se dérobe.
    v_gele := now() + make_interval(days => p_stabilite_jours);

    -- ABS-5 : sauf si la personne n'est plus là ce jour-là. Le gel protège un
    -- plan encore tenable ; il n'a pas à protéger un plan devenu impossible.
    -- Sans cette exception, déclarer un départ pour le week-end prochain — le
    -- cas courant, puisqu'on s'y prend rarement un mois à l'avance — ne
    -- déplacerait rien du tout.
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

            -- PLA-9 : quand il n'existe aucune intersection, on le dit. Placer la
            -- tâche au hasard reviendrait à proposer un moment où l'un des deux
            -- n'est pas là, ce qui décrédibilise tout le reste du planning.
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
-- Bilan du matin                                                 (opération 7)
--
-- Une notification par utilisateur, contenant sa journée et ses retards. Les
-- occurrences annoncées passent à « notifiée », ce qui fige leur créneau : sans
-- cela, le planning changerait entre le message du matin et le soir.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bilan_du_matin() RETURNS INTEGER
LANGUAGE plpgsql AS $$
DECLARE
    u          RECORD;
    o          RECORD;
    v_lignes   TEXT[];
    v_retards  TEXT[];
    v_bloquees TEXT[];
    v_pannes   TEXT[];
    v_contenu  TEXT;
    v_envoyees INTEGER := 0;
    v_jour     DATE := jour_de(now());
BEGIN
    -- L'ordre est explicite : sans lui, la sortie dépendrait de l'ordre
    -- physique des lignes, qui change à la première mise à jour venue.
    FOR u IN SELECT id_utilisateur, pseudo, role FROM utilisateur WHERE actif
              ORDER BY id_utilisateur LOOP
        v_lignes   := ARRAY[]::TEXT[];
        v_retards  := ARRAY[]::TEXT[];
        v_bloquees := ARRAY[]::TEXT[];
        v_pannes   := ARRAY[]::TEXT[];

        -- Ce qui est prévu aujourd'hui.
        FOR o IN
            SELECT oc.id_occurrence, oc.creneau, oc.rappel_journee, oc.nb_relances,
                   t.libelle
              FROM occurrence oc
              JOIN tache t ON t.id_tache = oc.id_tache
             WHERE oc.id_utilisateur = u.id_utilisateur
               AND oc.statut IN ('planifiee', 'notifiee')
               AND oc.creneau IS NOT NULL
               AND jour_de(lower(oc.creneau)) = v_jour
             ORDER BY lower(oc.creneau)
        LOOP
            v_lignes := v_lignes || (
                CASE WHEN o.rappel_journee
                     THEN '• ' || o.libelle
                     ELSE '• ' || to_char(lower(o.creneau) AT TIME ZONE 'Europe/Paris', 'HH24hMI')
                          || ' ' || o.libelle
                END
                || CASE WHEN o.nb_relances > 0
                        THEN ' (en retard depuis ' || o.nb_relances || ' j)'
                        ELSE '' END);

            -- Le créneau communiqué est figé (PLA-5).
            UPDATE occurrence SET statut = 'notifiee'
             WHERE id_occurrence = o.id_occurrence AND statut = 'planifiee';
        END LOOP;

        -- Ce qui traîne.
        SELECT array_agg('• ' || tache_libelle || ' (' || jours_de_retard || ' j)'
                         ORDER BY jours_de_retard DESC)
          INTO v_retards
          FROM v_occurrence
         WHERE id_utilisateur = u.id_utilisateur
           AND en_retard
           AND (creneau IS NULL OR jour_de(debut) <> v_jour);

        -- Ce que le moteur n'a pas su placer.
        SELECT array_agg('• ' || tache_libelle || ' : ' || motif)
          INTO v_bloquees
          FROM v_occurrence
         WHERE id_utilisateur = u.id_utilisateur
           AND statut = 'a_placer'
           AND motif IS NOT NULL;

        -- Les pannes de collecte ne concernent que l'administrateur.
        IF u.role = 'admin' THEN
            SELECT array_agg('• ' || libelle)
              INTO v_pannes
              FROM v_source_sante
             WHERE etat_calcule = 'en_panne' AND active;
        END IF;

        v_contenu := '';
        IF array_length(v_lignes, 1) > 0 THEN
            v_contenu := 'Aujourd''hui :' || E'\n' || array_to_string(v_lignes, E'\n');
        END IF;
        IF array_length(v_retards, 1) > 0 THEN
            v_contenu := v_contenu || CASE WHEN v_contenu = '' THEN '' ELSE E'\n\n' END
                         || 'En retard :' || E'\n' || array_to_string(v_retards, E'\n');
        END IF;
        IF array_length(v_bloquees, 1) > 0 THEN
            v_contenu := v_contenu || CASE WHEN v_contenu = '' THEN '' ELSE E'\n\n' END
                         || 'Sans créneau :' || E'\n' || array_to_string(v_bloquees, E'\n');
        END IF;
        IF array_length(v_pannes, 1) > 0 THEN
            v_contenu := v_contenu || CASE WHEN v_contenu = '' THEN '' ELSE E'\n\n' END
                         || 'Collecte en panne :' || E'\n' || array_to_string(v_pannes, E'\n');
        END IF;

        -- Un bilan vide tous les matins ferait couper les notifications en une
        -- semaine. Quand il n'y a rien à dire, on se tait.
        IF v_contenu <> '' THEN
            INSERT INTO notification (id_utilisateur, type, contenu)
            VALUES (u.id_utilisateur, 'bilan', v_contenu);
            v_envoyees := v_envoyees + 1;
        END IF;
    END LOOP;

    RETURN v_envoyees;
END $$;


-- -----------------------------------------------------------------------------
-- Relance du soir                                                (opération 8)
--
-- Une notification par tâche, et non un récapitulatif : c'est elle qui portera
-- les boutons « fait / reporter / refuser » dans le bot.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION relance_du_soir() RETURNS INTEGER
LANGUAGE plpgsql AS $$
DECLARE
    o        RECORD;
    v_creees INTEGER := 0;
    v_jour   DATE := jour_de(now());
BEGIN
    FOR o IN
        SELECT oc.id_occurrence, oc.id_utilisateur, t.libelle
          FROM occurrence oc
          JOIN tache t ON t.id_tache = oc.id_tache
         WHERE oc.statut = 'notifiee'
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
END $$;


-- -----------------------------------------------------------------------------
-- Report d'office du soir                                        (opération 8)
--
-- L'occurrence n'est pas recréée : elle glisse au lendemain et son compteur de
-- relances augmente. C'est ce qui permet de dire « en retard depuis 3 jours »
-- plutôt que de laisser une chaîne d'occurrences abandonnées (EXE-6).
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

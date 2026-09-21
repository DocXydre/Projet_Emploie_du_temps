-- =============================================================================
-- Stock d'uniforme : les fonctions supprimées par la 031, telles qu'en base.
--
-- Deux fonctions vivantes ont aussi perdu un morceau, reproduit en fin de
-- fichier : placer_taches appelait declencher_lessive pour chaque utilisateur
-- actif, et trg_occurrence_apres_validation mettait l'uniforme à sécher.
-- =============================================================================

CREATE OR REPLACE FUNCTION declencher_lessive(p_utilisateur integer)
 RETURNS integer
 LANGUAGE plpgsql
AS $function$
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

    -- UNI-11 : l'échéance est dépassée, le linge n'aura pas le temps de
    -- sécher. On envoie une alerte au lieu de planifier une lessive.
    --
    -- Ce contrôle passe avant celui de l'occurrence existante, pour que
    -- l'alerte parte même si une lessive était déjà prévue.
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
END $function$

;

CREATE OR REPLACE FUNCTION projeter_stock(p_utilisateur integer)
 RETURNS TABLE(article character varying, jour_rupture date, echeance_lessive timestamp with time zone, alerte boolean)
 LANGUAGE plpgsql
 STABLE
AS $function$
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
END $function$

;

CREATE OR REPLACE FUNCTION consommer_uniforme(p_jour date)
 RETURNS integer
 LANGUAGE plpgsql
AS $function$
DECLARE
    a       RECORD;
    v_sales INTEGER := 0;
BEGIN
    -- Pas de service ce jour-là : l'uniforme n'a pas été porté.
    IF NOT EXISTS (
        SELECT 1 FROM occupation
         WHERE type = 'travail' AND jour_de(lower(periode)) = p_jour
    ) THEN
        RETURN 0;
    END IF;

    FOR a IN SELECT * FROM article_travail ORDER BY id_article LOOP
        -- UNI-6 : journée déjà comptée, on passe. C'est ce qui permet de
        -- rattraper plusieurs jours d'un coup sans rien salir en double.
        CONTINUE WHEN a.dernier_jour_compte IS NOT NULL
                  AND a.dernier_jour_compte >= p_jour;

        IF a.journees_portees + 1 >= a.jours_par_unite THEN
            INSERT INTO mouvement_stock (id_article, type, quantite)
            VALUES (a.id_article, 'salissure', 1);

            UPDATE article_travail
               SET journees_portees = 0, dernier_jour_compte = p_jour
             WHERE id_article = a.id_article;

            v_sales := v_sales + 1;
        ELSE
            UPDATE article_travail
               SET journees_portees = a.journees_portees + 1,
                   dernier_jour_compte = p_jour
             WHERE id_article = a.id_article;
        END IF;
    END LOOP;

    RETURN v_sales;
END $function$

;

CREATE OR REPLACE FUNCTION rattraper_uniforme(p_max_jours integer DEFAULT 60)
 RETURNS integer
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_depuis DATE;
    v_jour   DATE;
    v_sales  INTEGER := 0;
BEGIN
    SELECT COALESCE(max(dernier_jour_compte), jour_de(now()) - p_max_jours)
      INTO v_depuis
      FROM article_travail;

    v_jour := GREATEST(v_depuis + 1, jour_de(now()) - p_max_jours);

    WHILE v_jour < jour_de(now()) LOOP
        v_sales := v_sales + consommer_uniforme(v_jour);
        v_jour := v_jour + 1;
    END LOOP;

    RETURN v_sales;
END $function$

;

CREATE OR REPLACE FUNCTION recaler_uniforme(p_code character varying, p_propre integer)
 RETURNS TABLE(code character varying, quantite_propre integer, ecart integer)
 LANGUAGE plpgsql
AS $function$
DECLARE
    a      RECORD;
    v_ecart INTEGER;
BEGIN
    SELECT * INTO a FROM article_travail WHERE article_travail.code = p_code;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Article % inconnu', p_code USING ERRCODE = 'no_data_found';
    END IF;

    IF p_propre < 0 OR p_propre > a.quantite_totale THEN
        RAISE EXCEPTION 'Un stock propre de % est impossible : % en tout',
                        p_propre, a.quantite_totale
              USING ERRCODE = 'check_violation';
    END IF;

    v_ecart := p_propre - a.quantite_propre;

    -- La contrainte interdit une quantité nulle : rien à écrire si le compte
    -- était déjà bon.
    IF v_ecart <> 0 THEN
        INSERT INTO mouvement_stock (id_article, type, quantite)
        VALUES (a.id_article, 'recalage', v_ecart);
    END IF;

    UPDATE article_travail
       SET journees_portees    = 0,
           dernier_jour_compte = GREATEST(COALESCE(dernier_jour_compte, jour_de(now())),
                                          jour_de(now())),
           -- Ce qu'on déclare propre est portable tout de suite : on ne va pas
           -- attendre un séchage qui a déjà eu lieu.
           disponible_le       = CASE WHEN p_propre > 0 THEN NULL ELSE disponible_le END,
           date_maj            = now()
     WHERE id_article = a.id_article;

    RETURN QUERY
    SELECT v.code, v.quantite_propre, v_ecart
      FROM article_travail v WHERE v.id_article = a.id_article;
END $function$

;

CREATE OR REPLACE FUNCTION trg_mouvement_appliquer()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
DECLARE v_delta INTEGER;
BEGIN
    v_delta := CASE NEW.type
                   WHEN 'salissure'     THEN -abs(NEW.quantite)
                   WHEN 'lavage'        THEN  abs(NEW.quantite)
                   WHEN 'retour_propre' THEN  abs(NEW.quantite)
                   WHEN 'recalage'      THEN  NEW.quantite
               END;

    UPDATE article_travail
       SET quantite_propre = LEAST(GREATEST(quantite_propre + v_delta, 0), quantite_totale),
           date_maj        = now()
     WHERE id_article = NEW.id_article;

    RETURN NULL;
END $function$

;

CREATE OR REPLACE FUNCTION trg_mouvement_compteur()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    IF NEW.type = 'retour_propre' THEN
        UPDATE article_travail SET journees_portees = 0
         WHERE id_article = NEW.id_article;
    END IF;
    RETURN NEW;
END $function$

;



-- -----------------------------------------------------------------------------
-- Retiré de placer_taches, juste après generer_seances_sport :
-- -----------------------------------------------------------------------------
--
--     FOR u IN SELECT id_utilisateur FROM utilisateur WHERE actif ORDER BY id_utilisateur LOOP
--         PERFORM declencher_lessive(u.id_utilisateur);
--     END LOOP;
--
-- (avec la variable « u RECORD; » dans le DECLARE)


-- -----------------------------------------------------------------------------
-- Retiré de trg_occurrence_apres_validation, après le bloc TAC-10 :
-- -----------------------------------------------------------------------------
/*
    -- ---- UNI-13 : le linge lavé n'est pas portable tout de suite ---------------
    --
    -- Seuls les articles qui avaient des unités sales partent en séchage. Un
    -- pantalon déjà propre ne devient pas indisponible parce qu'on a lavé les
    -- t-shirts. Le CTE fige la liste avant que le mouvement ne remette les
    -- compteurs à niveau.
    IF t.lave_uniforme THEN
        WITH sales AS (
            SELECT a.id_article,
                   a.quantite_totale - a.quantite_propre AS nb,
                   a.heures_sechage
              FROM article_travail a
             WHERE a.quantite_propre < a.quantite_totale
        ),
        mise_a_secher AS (
            UPDATE article_travail a
               SET disponible_le = NEW.date_faite + make_interval(hours => s.heures_sechage),
                   date_maj      = now()
              FROM sales s
             WHERE s.id_article = a.id_article
            RETURNING a.id_article
        )
        INSERT INTO mouvement_stock (id_article, id_occurrence, type, quantite)
        SELECT s.id_article, NEW.id_occurrence, 'lavage', s.nb FROM sales s;
    END IF;
*/

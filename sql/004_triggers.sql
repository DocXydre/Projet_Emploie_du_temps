-- rejouable : ce fichier ne contient que des CREATE OR REPLACE ou des IF NOT
--             EXISTS. Le rejouer après modification est sans effet de bord.
--             Les déclencheurs utilisent CREATE OR REPLACE TRIGGER, apparu
--             avec PostgreSQL 14 — sans quoi rejouer échouerait sur un
--             déclencheur déjà posé.
-- =============================================================================
-- 004 : triggers
--
-- Les contraintes qu'un CHECK ne sait pas exprimer : celles qui portent sur
-- une transition d'état, sur une autre table, ou sur l'heure courante.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- Une occurrence hérite de la nature de sa tâche                          (TAC-2)
--
-- Dénormalisation assumée : une contrainte d'exclusion ne sait pas lire une
-- table liée. Ces deux drapeaux conditionnent le chevauchement et la règle de
-- machine unique, ils doivent donc vivre sur la ligne.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_occurrence_heriter_tache() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
DECLARE t RECORD;
BEGIN
    SELECT rappel_journee, utilise_machine, id_utilisateur_defaut
      INTO t FROM tache WHERE id_tache = NEW.id_tache;

    NEW.rappel_journee  := t.rappel_journee;
    NEW.utilise_machine := t.utilise_machine;

    -- L'assignation par défaut ne s'applique qu'aux occurrences engendrées par
    -- le système. Une création manuelle dit exactement ce qu'elle veut, y
    -- compris « personne » : c'est ce qui permet à un refus de laisser la tâche
    -- libre pour que l'autre la reprenne, plutôt que de la rendre aussitôt à
    -- celui qui vient de la refuser.
    IF NEW.id_utilisateur IS NULL AND NEW.origine <> 'manuelle' THEN
        NEW.id_utilisateur := t.id_utilisateur_defaut;
    END IF;

    RETURN NEW;
END $$;

CREATE OR REPLACE TRIGGER occurrence_heriter_tache
    BEFORE INSERT ON occurrence
    FOR EACH ROW EXECUTE FUNCTION trg_occurrence_heriter_tache();


-- -----------------------------------------------------------------------------
-- Contrôle des transitions de statut                            (EXE-1, EXE-5)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_occurrence_transition() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
    -- EXE-1 : on ne valide pas une tâche dans le futur. Ce contrôle ne peut pas
    -- être un CHECK, now() n'étant pas immutable.
    IF NEW.date_faite IS NOT NULL AND NEW.date_faite > now() THEN
        RAISE EXCEPTION 'Une tâche ne peut pas être validée dans le futur'
              USING ERRCODE = 'check_violation';
    END IF;

    -- EXE-6 : le compteur de relances ne redescend jamais.
    IF NEW.nb_relances < OLD.nb_relances THEN
        RAISE EXCEPTION 'Le compteur de relances ne peut pas diminuer'
              USING ERRCODE = 'check_violation';
    END IF;

    RETURN NEW;
END $$;

CREATE OR REPLACE TRIGGER occurrence_transition
    BEFORE UPDATE ON occurrence
    FOR EACH ROW EXECUTE FUNCTION trg_occurrence_transition();


-- -----------------------------------------------------------------------------
-- Une occurrence close ne se touche plus                                 (EXE-5)
--
-- Comparer les valeurs avant et après ne suffit pas : revalider une occurrence
-- dans la même transaction réécrit date_faite avec le même now(), puisque
-- now() est figé pour toute la transaction. Le changement serait donc invisible
-- alors que l'intention, elle, est bien une seconde validation.
--
-- On passe donc par un trigger de colonnes : PostgreSQL le déclenche dès que
-- l'une d'elles figure dans le SET, que la valeur change ou non.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_occurrence_close() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
    IF OLD.statut IN ('faite', 'reportee', 'abandonnee') THEN
        RAISE EXCEPTION 'L''occurrence % est close (%) et ne peut plus être modifiée',
              OLD.id_occurrence, OLD.statut
              USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END $$;

CREATE OR REPLACE TRIGGER occurrence_close
    BEFORE UPDATE OF statut, date_faite, fenetre, creneau ON occurrence
    FOR EACH ROW EXECUTE FUNCTION trg_occurrence_close();


-- -----------------------------------------------------------------------------
-- Une seule machine par jour                                             (UNI-12)
--
-- Le chevauchement ne suffit pas : deux lessives à 21h45 et 23h00 ne se
-- chevauchent pas mais ne peuvent pas tourner le même soir.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_machine_unique() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.utilise_machine
       AND NEW.creneau IS NOT NULL
       AND NEW.statut IN ('planifiee', 'notifiee')
       AND machine_occupee(jour_de(lower(NEW.creneau)), NEW.id_occurrence) THEN

        RAISE EXCEPTION 'Une seule machine par jour : le % est déjà pris',
              to_char(lower(NEW.creneau) AT TIME ZONE 'Europe/Paris', 'DD/MM')
              USING ERRCODE = 'check_violation';
    END IF;

    RETURN NEW;
END $$;

CREATE OR REPLACE TRIGGER occurrence_machine_unique
    BEFORE INSERT OR UPDATE OF creneau, statut ON occurrence
    FOR EACH ROW EXECUTE FUNCTION trg_machine_unique();


-- -----------------------------------------------------------------------------
-- Après validation : récurrence, enchaînements et stock     (EXE-1, EXE-2, EXE-3, UNI-13)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_occurrence_apres_validation() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
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
    -- Les occurrences pré-générées supposaient que la tâche serait faite en fin
    -- de fenêtre. La validation dit quand elle l'a vraiment été : tout ce qui
    -- suivait est à refaire. On efface plutôt que d'annuler, parce qu'une
    -- prévision jamais annoncée n'est pas un engagement dont il faut garder
    -- trace — seuls les créneaux communiqués en méritent une.
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

    RETURN NULL;
END $$;

CREATE OR REPLACE TRIGGER occurrence_apres_validation
    AFTER UPDATE OF statut ON occurrence
    FOR EACH ROW
    WHEN (NEW.statut = 'faite' AND OLD.statut IS DISTINCT FROM 'faite')
    EXECUTE FUNCTION trg_occurrence_apres_validation();


-- -----------------------------------------------------------------------------
-- Le stock se recalcule à chaque mouvement                               (UNI-3)
--
-- quantite_propre n'est jamais écrite directement par l'API : elle est le
-- résultat du journal des mouvements.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_mouvement_appliquer() RETURNS TRIGGER
LANGUAGE plpgsql AS $$
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
END $$;

CREATE OR REPLACE TRIGGER mouvement_appliquer
    AFTER INSERT ON mouvement_stock
    FOR EACH ROW EXECUTE FUNCTION trg_mouvement_appliquer();


-- -----------------------------------------------------------------------------
-- Une journée de travail consomme de l'uniforme                          (UNI-4)
--
-- Le mouvement est enregistré quand la journée de travail est passée : c'est
-- le moment où le vêtement est réellement sale.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION consommer_uniforme(p_jour DATE) RETURNS INTEGER
LANGUAGE plpgsql AS $$
DECLARE
    a         RECORD;
    v_faits   INTEGER := 0;
    v_jours_travailles INTEGER;
BEGIN
    SELECT count(*) INTO v_jours_travailles
      FROM occupation
     WHERE type = 'travail' AND jour_de(lower(periode)) = p_jour;

    IF v_jours_travailles = 0 THEN
        RETURN 0;
    END IF;

    FOR a IN SELECT * FROM article_travail LOOP
        -- Une unité couvre jours_par_unite journées de travail : on ne salit
        -- un pantalon qu'un jour sur deux.
        IF (p_jour - DATE '2000-01-01') % a.jours_par_unite = 0 THEN
            INSERT INTO mouvement_stock (id_article, type, quantite)
            VALUES (a.id_article, 'salissure', 1);
            v_faits := v_faits + 1;
        END IF;
    END LOOP;

    RETURN v_faits;
END $$;

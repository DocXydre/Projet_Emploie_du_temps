-- rejouable : ce fichier ne contient que des CREATE OR REPLACE.
-- =============================================================================
-- 036 : du roulement, et le coup de main                 (PLA-12, EXE-14, EXE-15)
--
-- Trois défauts d'usage, constatés une fois le deuxième compte en service.
--
-- Le premier : toujours les mêmes tâches pour les mêmes. La répartition ne
-- regardait que la charge du moment, jamais qui avait fait quoi la fois
-- d'avant. À charges égales, le premier de la liste l'emportait donc
-- systématiquement, et la litière restait à vie du même côté.
--
-- Le deuxième : une tâche prévue pour l'autre ne pouvait pas être validée par
-- celui qui l'avait faite. On passe l'aspirateur parce qu'il faut le passer,
-- pas parce que le planning le demande, et le système répondait « cette tâche
-- est assignée à un autre utilisateur ».
--
-- Le troisième : une tâche faite en avance ne décalait rien tout de suite. La
-- récurrence repartait bien de la date réelle, mais le planning attendait le
-- placement de la nuit pour en tenir compte.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 1. Qui l'a faite en dernier                                          (PLA-12)
--
-- La dernière occurrence attribuée, faite ou seulement prévue. Prévue compte
-- aussi : pendant un placement, les occurrences d'une même tâche se suivent, et
-- c'est précisément entre elles qu'on veut alterner.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION dernier_a_faire(p_tache INTEGER) RETURNS INTEGER
LANGUAGE sql STABLE AS $$
    SELECT o.id_utilisateur
      FROM occurrence o
     WHERE o.id_tache = p_tache
       AND o.id_utilisateur IS NOT NULL
       AND o.statut IN ('faite', 'planifiee', 'notifiee')
     ORDER BY COALESCE(o.date_faite, lower(o.creneau), upper(o.fenetre)) DESC,
              o.id_occurrence DESC
     LIMIT 1;
$$;

COMMENT ON FUNCTION dernier_a_faire IS
    'La personne de la dernière occurrence de cette tâche, faite ou prévue.
     C''est elle que le tour suivant évite (PLA-12).';


CREATE OR REPLACE FUNCTION charge_domestique(p_utilisateur INTEGER) RETURNS INTEGER
LANGUAGE sql STABLE AS $$
    -- PLA-10 : le sport est personnel, il n'entre pas dans la balance.
    --
    -- Une tâche à deux non plus : le grand nettoyage dure deux heures et se
    -- fait ensemble. Le compter chez celui à qui il est nominalement assigné
    -- lui donnait deux heures d'avance imaginaire, et lui épargnait tout le
    -- reste pendant des semaines.
    SELECT COALESCE(sum(t.duree_minutes), 0)::INTEGER
      FROM occurrence o
      JOIN tache t ON t.id_tache = o.id_tache
     WHERE o.id_utilisateur = p_utilisateur
       AND t.categorie <> 'sport'
       AND NOT t.requiert_les_deux
       AND o.statut IN ('a_placer', 'planifiee', 'notifiee');
$$;

COMMENT ON FUNCTION charge_domestique IS
    'Minutes de tâches domestiques encore à faire, sport et tâches à deux
     exclus, pour équilibrer la répartition (PLA-10, PLA-12).';


-- -----------------------------------------------------------------------------
-- 2. À qui revient la prochaine                                        (PLA-12)
--
-- Le tour d'abord, la balance ensuite. On donne la tâche à qui ne l'a pas eue
-- la dernière fois, sauf si cela creuse l'écart de charge au-delà d'une heure :
-- une alternance aveugle donnerait tout le ménage d'une semaine à celui qui est
-- déjà pris, au motif que c'était son tour.
--
-- Une heure de tolérance, parce que les tâches durent de dix à quarante-cinq
-- minutes : en dessous, le moindre écart casserait l'alternance et l'on
-- reviendrait au défaut qu'on corrige.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION choisir_assigne(p_tache INTEGER, p_fenetre TSTZRANGE)
RETURNS INTEGER LANGUAGE plpgsql STABLE AS $$
DECLARE
    TOLERANCE_MINUTES CONSTANT INTEGER := 60;

    t              RECORD;
    u              RECORD;
    v_dernier      INTEGER;
    v_charge       INTEGER;
    v_moins_charge INTEGER := NULL;
    v_charge_min   INTEGER := NULL;
    v_tour         INTEGER := NULL;
    v_charge_tour  INTEGER := NULL;
BEGIN
    SELECT * INTO t FROM tache WHERE id_tache = p_tache;

    -- ABS-2 : l'assignation fixée tient tant que la personne est là. Le pliage
    -- du linge revient à Lorette, et le roulement ne la remplace pas.
    IF t.id_utilisateur_defaut IS NOT NULL
       AND present_dans(t.id_utilisateur_defaut, p_fenetre) THEN
        RETURN t.id_utilisateur_defaut;
    END IF;

    v_dernier := dernier_a_faire(p_tache);

    FOR u IN SELECT id_utilisateur FROM utilisateur WHERE actif ORDER BY id_utilisateur LOOP
        CONTINUE WHEN NOT present_dans(u.id_utilisateur, p_fenetre);

        v_charge := charge_domestique(u.id_utilisateur);

        IF v_charge_min IS NULL OR v_charge < v_charge_min THEN
            v_moins_charge := u.id_utilisateur;
            v_charge_min   := v_charge;
        END IF;

        IF u.id_utilisateur IS DISTINCT FROM v_dernier
           AND (v_charge_tour IS NULL OR v_charge < v_charge_tour) THEN
            v_tour        := u.id_utilisateur;
            v_charge_tour := v_charge;
        END IF;
    END LOOP;

    IF v_tour IS NOT NULL
       AND v_charge_tour <= COALESCE(v_charge_min, 0) + TOLERANCE_MINUTES THEN
        RETURN v_tour;
    END IF;

    RETURN v_moins_charge;   -- NULL si l'appartement est vide toute la fenêtre
END $$;

COMMENT ON FUNCTION choisir_assigne IS
    'Le tour de celui qui ne l''a pas eue la dernière fois, tant que l''écart de
     charge reste inférieur à une heure ; sinon le moins chargé (PLA-12).';


-- -----------------------------------------------------------------------------
-- 3. Celui qui la fait est celui qui la coche                          (EXE-14)
--
-- L'ancienne règle refusait la validation d'une tâche assignée à l'autre, sauf
-- à l'administrateur. À deux dans un appartement, c'est l'inverse de la vie
-- réelle : la vaisselle est faite par qui passe devant. La tâche est donc
-- recréditée à celui qui la valide, ce qui la retire du planning de l'autre et
-- compte pour le roulement suivant.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION valider_occurrence(
    p_occurrence  INTEGER,
    p_acteur      INTEGER,
    p_date_reelle TIMESTAMPTZ DEFAULT NULL
) RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE
    o RECORD;
BEGIN
    SELECT * INTO o FROM occurrence WHERE id_occurrence = p_occurrence FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Occurrence % introuvable', p_occurrence
              USING ERRCODE = 'no_data_found';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM utilisateur
                    WHERE id_utilisateur = p_acteur AND actif) THEN
        RAISE EXCEPTION 'Compte % inconnu ou désactivé', p_acteur
              USING ERRCODE = 'insufficient_privilege';
    END IF;

    UPDATE occurrence
       SET statut         = 'faite',
           id_utilisateur = p_acteur,
           date_faite     = COALESCE(p_date_reelle, now())
     WHERE id_occurrence = p_occurrence;

    RETURN p_occurrence;
END $$;

COMMENT ON FUNCTION valider_occurrence IS
    'Marque une occurrence faite et la crédite à celui qui la valide, même
     lorsqu''elle était prévue pour l''autre (EXE-14).';


-- -----------------------------------------------------------------------------
-- 4. Déclarer une tâche qui n'était pas la sienne                      (EXE-15)
--
-- `declarer_faite` ne reprenait que les occurrences sans assigné ou assignées à
-- l'appelant : déclarer une tâche prévue pour l'autre en créait une deuxième,
-- et la sienne restait au planning. On reprend désormais la plus proche, quel
-- que soit son assigné, et la validation la recrédite (EXE-14).
--
-- Au passage, la fonction ne fonctionnait plus du tout : elle lisait et
-- écrivait `echeance_min` et `echeance_max`, deux colonnes remplacées depuis
-- par la fenêtre. Toute déclaration spontanée échouait donc, et rien ne le
-- disait faute de test. C'est corrigé ici, et testé.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION declarer_faite(
    p_utilisateur INTEGER,
    p_code_tache  VARCHAR,
    p_quand       TIMESTAMPTZ DEFAULT NULL
) RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE
    t            RECORD;
    v_occurrence INTEGER;
    v_quand      TIMESTAMPTZ := COALESCE(p_quand, now());
BEGIN
    SELECT * INTO t FROM tache WHERE code = p_code_tache AND active;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Tâche % inconnue ou inactive', p_code_tache
              USING ERRCODE = 'no_data_found';
    END IF;

    IF v_quand > now() THEN
        RAISE EXCEPTION 'On ne déclare pas fait ce qui ne l''est pas encore'
              USING ERRCODE = 'check_violation';
    END IF;

    -- La plus proche d'abord : si deux occurrences traînent, c'est celle dont
    -- l'échéance approche que l'on vient de faire. L'assigné n'entre plus dans
    -- le choix : une tâche faite est une tâche faite.
    SELECT id_occurrence INTO v_occurrence
      FROM occurrence
     WHERE id_tache = t.id_tache
       AND statut IN ('a_placer', 'planifiee', 'notifiee')
       -- Une séance de sport à déterminer ne se déclare pas : elle se choisit.
       AND origine <> 'quota'
     ORDER BY upper(fenetre)
     LIMIT 1;

    IF v_occurrence IS NULL THEN
        INSERT INTO occurrence (id_tache, id_utilisateur, fenetre, statut, origine, motif)
        VALUES (t.id_tache, p_utilisateur,
                fenetre_pour(t.rappel_journee, v_quand,
                             v_quand + make_interval(days => t.periodicite_max_jours)),
                'a_placer', 'manuelle', 'Déclarée faite hors planning')
        RETURNING id_occurrence INTO v_occurrence;
    END IF;

    PERFORM valider_occurrence(v_occurrence, p_utilisateur, v_quand);
    RETURN v_occurrence;
END $$;

COMMENT ON FUNCTION declarer_faite IS
    'Valide une tâche faite spontanément, même prévue pour quelqu''un d''autre.
     Reprend l''occurrence ouverte la plus proche, en crée une sinon, et la
     récurrence repart de la date déclarée (EXE-11, EXE-15).';

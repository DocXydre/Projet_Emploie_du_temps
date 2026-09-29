-- rejouable : ce fichier ne contient que des ALTER ... IF NOT EXISTS, des
--             CREATE OR REPLACE et des mises à jour idempotentes.
-- =============================================================================
-- 037 : le sport de chacun                                    (SPT-28, SPT-29)
--
-- Deux défauts, tous deux visibles depuis que le deuxième compte est en
-- service.
--
-- Le premier : une seule personne avait du sport. `sportifs()` rendait
-- l'assigné par défaut de la tâche SPORT, sinon le premier compte créé.
-- Lorette n'avait donc ni semaines, ni propositions, ni réservations, et rien
-- ne le disait. Le sport est personnel : chacun a les siennes.
--
-- Le second : le minimum hebdomadaire était le même pour tout le monde, écrit
-- sur la tâche. Trois séances par semaine pour l'un peut être absurde pour
-- l'autre. Le minimum devient donc un réglage par personne, celui de la tâche
-- servant de valeur par défaut.
--
-- Au passage, la piscine repasse en dernier recours : elle était le sport
-- préféré du moteur, et elle revenait dans toutes les propositions alors qu'on
-- n'y va plus (SPT-6).
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 1. Un minimum par personne                                           (SPT-28)
--
-- NULL veut dire « comme la tâche » : on ne recopie pas la valeur par défaut
-- dans chaque compte, sinon la changer une bonne fois demanderait de la
-- changer partout. Zéro est permis, et veut dire « pas de sport organisé » :
-- les écrans restent accessibles, mais plus rien n'est réservé d'office.
-- -----------------------------------------------------------------------------
ALTER TABLE utilisateur ADD COLUMN IF NOT EXISTS minimum_sport SMALLINT;

ALTER TABLE utilisateur DROP CONSTRAINT IF EXISTS utilisateur_minimum_sport_raisonnable;
ALTER TABLE utilisateur ADD CONSTRAINT utilisateur_minimum_sport_raisonnable
    CHECK (minimum_sport IS NULL OR minimum_sport BETWEEN 0 AND 7);

COMMENT ON COLUMN utilisateur.minimum_sport IS
    'Séances de sport par semaine pour ce compte. NULL suit le quota de la
     tâche SPORT, 0 veut dire aucune organisation automatique (SPT-28).';


CREATE OR REPLACE FUNCTION minimum_sport(p_utilisateur INTEGER) RETURNS INTEGER
LANGUAGE sql STABLE AS $$
    SELECT COALESCE(
        (SELECT u.minimum_sport FROM utilisateur u
          WHERE u.id_utilisateur = p_utilisateur AND u.actif),
        (SELECT t.quota_hebdomadaire FROM tache t WHERE t.code = 'SPORT' AND t.active),
        3);
$$;

COMMENT ON FUNCTION minimum_sport IS
    'Le minimum hebdomadaire de ce compte : le sien, sinon celui de la tâche,
     sinon trois (SPT-28).';


CREATE OR REPLACE FUNCTION regler_minimum_sport(p_utilisateur INTEGER,
                                                p_minimum     INTEGER)
RETURNS INTEGER LANGUAGE plpgsql AS $$
BEGIN
    IF p_minimum IS NULL OR p_minimum < 0 OR p_minimum > 7 THEN
        RAISE EXCEPTION 'Une fréquence se règle entre 0 et 7 séances par semaine'
              USING ERRCODE = 'check_violation';
    END IF;

    UPDATE utilisateur SET minimum_sport = p_minimum
     WHERE id_utilisateur = p_utilisateur AND actif;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Compte % inconnu ou désactivé', p_utilisateur
              USING ERRCODE = 'no_data_found';
    END IF;

    -- Les semaines suivent aussitôt : baisser sa fréquence libère des
    -- réservations, la monter en pose de nouvelles.
    PERFORM organiser_sport(p_utilisateur);
    RETURN minimum_sport(p_utilisateur);
END $$;

COMMENT ON FUNCTION regler_minimum_sport IS
    'Change la fréquence de sport d''un compte et réorganise ses trois
     semaines dans la foulée (SPT-28).';


-- -----------------------------------------------------------------------------
-- 2. Tout le monde fait du sport                                       (SPT-29)
--
-- Chaque compte actif a ses trois semaines. Celui qui n'en veut pas met sa
-- fréquence à zéro : il garde ses écrans et peut choisir une séance à la main,
-- mais rien ne lui est réservé.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION sportifs() RETURNS SETOF INTEGER
LANGUAGE sql STABLE AS $$
    SELECT u.id_utilisateur
      FROM utilisateur u
     WHERE u.actif
     ORDER BY u.id_utilisateur;
$$;

COMMENT ON FUNCTION sportifs() IS
    'Tous les comptes actifs : le sport est personnel, chacun a ses semaines
     et sa fréquence (SPT-29).';


-- -----------------------------------------------------------------------------
-- 3. Les semaines suivent la fréquence de chacun                (SPT-28, SPT-23)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION organiser_sport_semaine(
    p_utilisateur INTEGER,
    p_lundi       DATE,
    p_refaire     BOOLEAN DEFAULT FALSE
) RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE
    v_tache     INTEGER;
    v_minimum   INTEGER;
    v_choisies  INTEGER;
    v_reservees INTEGER;
    v_manque    INTEGER;
    v_jours     DATE[];
    v_creees    INTEGER := 0;
    p           RECORD;
BEGIN
    SELECT t.id_tache INTO v_tache
      FROM tache t WHERE t.code = 'SPORT' AND t.active;

    -- SPT-28 : le minimum est celui de la personne, pas celui de la tâche.
    v_minimum := minimum_sport(p_utilisateur);

    -- Une semaine passée ne se réorganise pas.
    IF v_tache IS NULL OR p_lundi + 7 <= jour_de(now()) THEN
        RETURN 0;
    END IF;

    -- Les réservations devenues fausses : jamais posées, ou tombées depuis un
    -- jour d'absence, un jour désormais choisi, ou sous une obligation apparue.
    DELETE FROM occurrence o
     WHERE o.id_utilisateur = p_utilisateur
       AND o.id_tache = v_tache
       AND o.origine = 'quota'
       AND o.statut IN ('a_placer', 'planifiee', 'notifiee')
       AND jour_de(COALESCE(o.debut_seance, lower(o.fenetre))) BETWEEN p_lundi AND p_lundi + 6
       AND (o.creneau IS NULL
            OR (lower(o.creneau) > now()
                AND (est_absent(p_utilisateur, jour_de(o.debut_seance))
                     OR EXISTS (SELECT 1 FROM occurrence c
                                 WHERE c.id_utilisateur = p_utilisateur
                                   AND c.id_tache = v_tache
                                   AND c.origine <> 'quota'
                                   AND c.statut IN ('planifiee', 'notifiee', 'faite')
                                   AND jour_de(COALESCE(c.debut_seance, lower(c.creneau)))
                                       = jour_de(o.debut_seance))
                     OR EXISTS (SELECT 1 FROM occupation oc
                                 WHERE oc.id_utilisateur = p_utilisateur
                                   AND oc.periode && o.creneau))));

    SELECT count(*) INTO v_choisies
      FROM occurrence o
     WHERE o.id_utilisateur = p_utilisateur
       AND o.id_tache = v_tache
       AND o.origine <> 'quota'
       AND o.statut IN ('planifiee', 'notifiee', 'faite')
       AND jour_de(COALESCE(o.debut_seance, lower(o.creneau))) BETWEEN p_lundi AND p_lundi + 6;

    -- Une réservation passée ne compte plus : elle attend d'être constatée
    -- (seances_a_determiner_passees), et une autre doit prendre le relais.
    SELECT count(*) INTO v_reservees
      FROM occurrence o
     WHERE o.id_utilisateur = p_utilisateur
       AND o.id_tache = v_tache
       AND o.origine = 'quota'
       AND o.statut IN ('planifiee', 'notifiee')
       AND lower(o.creneau) > now()
       AND jour_de(o.debut_seance) BETWEEN p_lundi AND p_lundi + 6;

    v_manque := v_minimum - v_choisies - v_reservees;

    -- Trop de réservations : une séance vient d'être choisie ailleurs. On
    -- repart des meilleures plutôt que de garder les restes. Celles déjà
    -- annoncées ce matin restent, sauf s'il le faut vraiment.
    IF (v_manque < 0 OR p_refaire) AND v_reservees > 0 THEN
        DELETE FROM occurrence o
         WHERE o.id_utilisateur = p_utilisateur
           AND o.id_tache = v_tache
           AND o.origine = 'quota'
           AND o.statut = 'planifiee'
           AND lower(o.creneau) > now()
           AND jour_de(o.debut_seance) BETWEEN p_lundi AND p_lundi + 6;

        SELECT count(*) INTO v_reservees
          FROM occurrence o
         WHERE o.id_utilisateur = p_utilisateur
           AND o.id_tache = v_tache
           AND o.origine = 'quota'
           AND o.statut = 'notifiee'
           AND lower(o.creneau) > now()
           AND jour_de(o.debut_seance) BETWEEN p_lundi AND p_lundi + 6;

        IF v_choisies + v_reservees > v_minimum THEN
            DELETE FROM occurrence o
             WHERE o.id_occurrence IN (
                   SELECT o2.id_occurrence FROM occurrence o2
                    WHERE o2.id_utilisateur = p_utilisateur
                      AND o2.id_tache = v_tache
                      AND o2.origine = 'quota'
                      AND o2.statut = 'notifiee'
                      AND lower(o2.creneau) > now()
                      AND jour_de(o2.debut_seance) BETWEEN p_lundi AND p_lundi + 6
                    ORDER BY o2.debut_seance DESC
                    LIMIT v_choisies + v_reservees - v_minimum);
            v_reservees := GREATEST(v_minimum - v_choisies, 0);
        END IF;

        v_manque := v_minimum - v_choisies - v_reservees;
    END IF;

    IF v_manque <= 0 THEN
        RETURN 0;
    END IF;

    SELECT COALESCE(array_agg(jour_de(o.debut_seance)), ARRAY[]::DATE[]) INTO v_jours
      FROM occurrence o
     WHERE o.id_utilisateur = p_utilisateur
       AND o.id_tache = v_tache
       AND o.origine = 'quota'
       AND o.statut IN ('planifiee', 'notifiee')
       AND jour_de(o.debut_seance) BETWEEN p_lundi AND p_lundi + 6;

    FOR p IN
        SELECT pr.*, ls.libelle AS lieu_libelle
          FROM propositions_sport(p_utilisateur, p_lundi, NULL, v_jours, v_manque) pr
          JOIN lieu_sport ls ON ls.id_lieu = pr.id_lieu
         ORDER BY pr.rang
    LOOP
        -- Ce qui était mobile dessous se replacera autour (SPT-23).
        UPDATE occurrence o
           SET creneau = NULL, statut = 'a_placer',
               motif = 'Déplacée par une réservation de sport'
         WHERE o.id_utilisateur = p_utilisateur
           AND o.statut = 'planifiee'
           AND NOT o.epinglee
           AND NOT o.rappel_journee
           AND o.origine <> 'quota'
           AND o.creneau && p.bloc;

        INSERT INTO occurrence (id_tache, id_utilisateur, fenetre, creneau, statut,
                                origine, id_lieu, debut_seance, motif)
        VALUES (v_tache, p_utilisateur,
                tstzrange(LEAST(debut_jour(p.jour), lower(p.bloc)),
                          GREATEST(debut_jour(p.jour + 1), upper(p.bloc)), '[)'),
                p.bloc, 'planifiee', 'quota', p.id_lieu, p.debut,
                format('À déterminer. Proposition : %s à %s. Choisis dans /organiser.',
                       p.lieu_libelle,
                       to_char(p.debut AT TIME ZONE 'Europe/Paris', 'HH24hMI')));

        v_creees := v_creees + 1;
    END LOOP;

    RETURN v_creees;
END $$;

COMMENT ON FUNCTION organiser_sport_semaine IS
    'Complète la semaine jusqu''au minimum du compte avec des réservations à
     déterminer, sur les meilleures propositions (SPT-18, SPT-23, SPT-28).';


-- -----------------------------------------------------------------------------
-- 4. L'alerte du lundi, personne par personne                  (SPT-27, SPT-28)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION alerte_sport_du_lundi() RETURNS INTEGER
LANGUAGE plpgsql AS $$
DECLARE
    u          INTEGER;
    v_lundi    DATE := lundi_de(jour_de(now()));
    v_minimum  INTEGER;
    v_choisies INTEGER;
    v_reserve  TEXT;
    v_contenu  TEXT;
    v_n        INTEGER := 0;
BEGIN
    FOR u IN SELECT s FROM sportifs() s LOOP
        v_minimum := minimum_sport(u);
        -- Fréquence à zéro : pas de sport organisé, donc pas de relance.
        CONTINUE WHEN v_minimum <= 0;

        PERFORM organiser_sport_semaine(u, v_lundi);

        SELECT count(*) INTO v_choisies
          FROM occurrence o
          JOIN tache t ON t.id_tache = o.id_tache
         WHERE o.id_utilisateur = u
           AND t.code = 'SPORT'
           AND o.origine <> 'quota'
           AND o.statut IN ('planifiee', 'notifiee', 'faite')
           AND jour_de(COALESCE(o.debut_seance, lower(o.creneau))) BETWEEN v_lundi AND v_lundi + 6;

        CONTINUE WHEN v_choisies >= v_minimum;

        SELECT string_agg('• ' || to_char(o.debut_seance AT TIME ZONE 'Europe/Paris',
                                          'DD/MM à HH24hMI')
                          || COALESCE(' (proposé : ' || l.libelle || ')', ''),
                          E'\n' ORDER BY o.debut_seance)
          INTO v_reserve
          FROM occurrence o
          LEFT JOIN lieu_sport l ON l.id_lieu = o.id_lieu
         WHERE o.id_utilisateur = u
           AND o.origine = 'quota'
           AND o.statut IN ('planifiee', 'notifiee')
           AND jour_de(o.debut_seance) BETWEEN v_lundi AND v_lundi + 6;

        v_contenu := CASE WHEN v_choisies = 0
                          THEN 'Sport : rien n''est choisi pour cette semaine.'
                          ELSE format('Sport : %s séance(s) choisie(s) sur %s minimum cette semaine.',
                                      v_choisies, v_minimum) END;
        IF v_reserve IS NOT NULL THEN
            v_contenu := v_contenu || E'\n\nÀ déterminer, réservé dans ton calendrier :\n'
                         || v_reserve;
        ELSE
            v_contenu := v_contenu || E'\n\nAucun créneau libre n''a pu être réservé.';
        END IF;

        INSERT INTO notification (id_utilisateur, type, contenu)
        VALUES (u, 'sport', v_contenu);
        v_n := v_n + 1;
    END LOOP;

    RETURN v_n;
END $$;

COMMENT ON FUNCTION alerte_sport_du_lundi IS
    'Un message le lundi matin par compte dont la semaine n''atteint pas son
     minimum. Une fréquence à zéro ne reçoit rien (SPT-27, SPT-28).';


-- -----------------------------------------------------------------------------
-- 5. La piscine en dernier recours                                      (SPT-6)
--
-- Le rang dit l'ordre de préférence du moteur : il essaie le rang 1, et ne
-- descend que si rien ne tient. La piscine était première et revenait donc
-- partout. Elle passe après tout le reste, sans rien perdre : ses horaires
-- continuent d'être relevés, elle reste choisissable à la main, et une
-- habitude de piscine reste proposée comme habitude.
-- -----------------------------------------------------------------------------
UPDATE tache_lieu tl
   SET rang = 9
  FROM lieu_sport l
 WHERE l.id_lieu = tl.id_lieu
   AND l.code = 'PISCINE_SUAPS'
   AND tl.rang < 9;

COMMENT ON COLUMN tache_lieu.rang IS
    'Ordre de préférence du moteur, 1 en premier. La piscine est à 9 : dernier
     recours tant qu''on n''y va pas (SPT-6).';


-- Les trois semaines de tout le monde, tout de suite : Lorette n'en avait
-- aucune, et les réservations de chacun se calent sur son emploi du temps.
SELECT organiser_sport();

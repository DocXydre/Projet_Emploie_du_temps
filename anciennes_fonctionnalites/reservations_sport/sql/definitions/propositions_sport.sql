-- -----------------------------------------------------------------------------
-- Les propositions d'une semaine                               (SPT-20, SPT-22)
--
-- Jusqu'à cinq, une par jour. D'abord les habitudes qui tiennent entièrement
-- dans l'emploi du temps, de la plus fréquente à la plus rare. Puis le moteur :
-- le meilleur sport et la meilleure heure de chaque jour restant, en étalant
-- sur la semaine plutôt qu'en enchaînant trois jours de suite.
--
-- Le rang dit l'ordre de préférence. Les réservations prennent les premiers.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION propositions_sport(
    p_utilisateur INTEGER,
    p_lundi       DATE,
    p_ignorer     INTEGER DEFAULT NULL,
    p_jours_pris  DATE[]  DEFAULT NULL,
    p_max         INTEGER DEFAULT 5
) RETURNS TABLE (
    rang        INTEGER,
    jour        DATE,
    id_lieu     INTEGER,
    debut       TIMESTAMPTZ,
    bloc        TSTZRANGE,
    origine     VARCHAR,
    pourcentage INTEGER
) LANGUAGE plpgsql STABLE AS $$
#variable_conflict use_column
DECLARE
    v_tache    INTEGER;
    v_premier  DATE := GREATEST(p_lundi, jour_de(now()));
    v_pris     DATE[];
    v_n        INTEGER := 0;
    h          RECORD;
    l          RECORD;
    d          DATE;
    v_jour     DATE;
    v_debut    TIMESTAMPTZ;
    -- Candidats du moteur, un par jour.
    c_jour     DATE[] := ARRAY[]::DATE[];
    c_lieu     INTEGER[] := ARRAY[]::INTEGER[];
    c_debut    TIMESTAMPTZ[] := ARRAY[]::TIMESTAMPTZ[];
    c_rang     INTEGER[] := ARRAY[]::INTEGER[];
    i          INTEGER;
    v_meilleur INTEGER;
    v_ecart    INTEGER;
    v_ecart_max INTEGER;
BEGIN
    SELECT t.id_tache INTO v_tache FROM tache t WHERE t.code = 'SPORT' AND t.active;
    IF v_tache IS NULL OR p_max <= 0 THEN
        RETURN;
    END IF;

    -- Les jours qui ont déjà leur séance choisie, et ceux qu'on demande
    -- d'écarter (les réservations existantes, quand on complète).
    SELECT COALESCE(array_agg(DISTINCT jour_de(COALESCE(o.debut_seance, lower(o.creneau)))),
                    ARRAY[]::DATE[])
      INTO v_pris
      FROM occurrence o
     WHERE o.id_utilisateur = p_utilisateur
       AND o.id_tache = v_tache
       AND o.origine <> 'quota'
       AND o.statut IN ('planifiee', 'notifiee', 'faite')
       AND o.id_occurrence IS DISTINCT FROM p_ignorer
       AND jour_de(COALESCE(o.debut_seance, lower(o.creneau))) BETWEEN p_lundi AND p_lundi + 6;
    v_pris := v_pris || COALESCE(p_jours_pris, ARRAY[]::DATE[]);

    -- 1. Les habitudes qui tiennent.
    FOR h IN
        SELECT hs.*
          FROM habitudes_sport(p_utilisateur, p_lundi) hs
          JOIN tache_lieu tl ON tl.id_lieu = hs.h_lieu AND tl.id_tache = v_tache
         ORDER BY hs.h_pourcentage DESC, hs.h_semaines DESC, tl.rang,
                  hs.h_jour, hs.h_heure
    LOOP
        EXIT WHEN v_n >= p_max;
        v_jour := p_lundi + h.h_jour - 1;
        CONTINUE WHEN v_jour < v_premier OR v_jour = ANY(v_pris);

        v_debut := (v_jour + h.h_heure) AT TIME ZONE 'Europe/Paris';
        CONTINUE WHEN obstacle_seance(p_utilisateur, h.h_lieu, v_debut, p_ignorer, TRUE)
                      IS NOT NULL;

        v_n := v_n + 1;
        rang        := v_n;
        jour        := v_jour;
        id_lieu     := h.h_lieu;
        debut       := v_debut;
        bloc        := bloc_de_seance(p_utilisateur, h.h_lieu, v_debut);
        origine     := 'habitude';
        pourcentage := h.h_pourcentage;
        RETURN NEXT;
        v_pris := v_pris || v_jour;
    END LOOP;

    IF v_n >= p_max THEN
        RETURN;
    END IF;

    -- 2. Le moteur : pour chaque jour libre, le sport préféré qui y tient.
    d := v_premier;
    WHILE d <= p_lundi + 6 LOOP
        IF NOT (d = ANY(v_pris)) THEN
            FOR l IN SELECT tl.id_lieu, tl.rang FROM tache_lieu tl
                      WHERE tl.id_tache = v_tache ORDER BY tl.rang, tl.id_lieu LOOP
                v_debut := meilleure_heure_sport(p_utilisateur, l.id_lieu, d, p_ignorer);
                IF v_debut IS NOT NULL THEN
                    c_jour  := c_jour  || d;
                    c_lieu  := c_lieu  || l.id_lieu;
                    c_debut := c_debut || v_debut;
                    c_rang  := c_rang  || l.rang::INTEGER;
                    EXIT;
                END IF;
            END LOOP;
        END IF;
        d := d + 1;
    END LOOP;

    -- Étaler : on retient chaque fois le jour le plus éloigné de ce qui est
    -- déjà pris cette semaine. À égalité, le sport préféré, puis le plus tôt.
    WHILE v_n < p_max AND COALESCE(array_length(c_jour, 1), 0) > 0 LOOP
        v_meilleur := NULL;
        v_ecart_max := -1;
        FOR i IN 1 .. array_length(c_jour, 1) LOOP
            CONTINUE WHEN c_jour[i] IS NULL;
            SELECT COALESCE(min(abs(c_jour[i] - p)), 99) INTO v_ecart
              FROM unnest(v_pris) p
             WHERE p BETWEEN p_lundi AND p_lundi + 6;
            IF v_ecart > v_ecart_max
               OR (v_ecart = v_ecart_max AND c_rang[i] < c_rang[v_meilleur]) THEN
                v_meilleur := i;
                v_ecart_max := v_ecart;
            END IF;
        END LOOP;
        EXIT WHEN v_meilleur IS NULL;

        v_n := v_n + 1;
        rang        := v_n;
        jour        := c_jour[v_meilleur];
        id_lieu     := c_lieu[v_meilleur];
        debut       := c_debut[v_meilleur];
        bloc        := bloc_de_seance(p_utilisateur, c_lieu[v_meilleur], c_debut[v_meilleur]);
        origine     := 'moteur';
        pourcentage := NULL;
        RETURN NEXT;

        v_pris := v_pris || c_jour[v_meilleur];
        c_jour[v_meilleur] := NULL;
    END LOOP;
END $$;

COMMENT ON FUNCTION propositions_sport IS
    'Jusqu''à p_max séances proposées pour la semaine, une par jour : les
     habitudes qui tiennent, puis le moteur, étalé sur la semaine (SPT-20,
     SPT-22).';

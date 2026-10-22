-- -----------------------------------------------------------------------------
-- Ce qui ne va pas dans une règle                      (CND-1, CND-7, CND-15)
--
-- Rend le motif d'un refus, ou rien. Les briques une à une (motif_brique),
-- puis la règle avec sa tâche : une brique ne contredit pas l'heure imposée, la
-- tâche à deux, ni une tâche qui ne naît que d'une autre.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION motif_regle(p_tache        INTEGER,
                                       p_briques     JSONB,
                                       p_validite     DATERANGE DEFAULT NULL,
                                       p_chaque_annee BOOLEAN   DEFAULT FALSE,
                                       p_frequence    JSONB     DEFAULT NULL)
RETURNS TEXT LANGUAGE plpgsql STABLE AS $$
DECLARE
    t        tache%ROWTYPE;
    b        JSONB;
    v_motif  TEXT;
    v_briques JSONB := COALESCE(p_briques, '[]'::JSONB);
    v_partie TEXT;
BEGIN
    SELECT * INTO t FROM tache WHERE id_tache = p_tache;
    IF NOT FOUND OR NOT t.active THEN
        RETURN 'Cette tâche n''existe pas, ou elle est arrêtée';
    END IF;
    IF t.categorie = 'sport' THEN
        RETURN 'Le sport a ses propres règles : c''est HAL qui place les séances';
    END IF;

    IF jsonb_typeof(v_briques) <> 'array' THEN
        RETURN 'Les briques d''une règle sont une liste';
    END IF;
    IF jsonb_array_length(v_briques) = 0 AND p_frequence IS NULL THEN
        RETURN 'Une règle a au moins une brique';
    END IF;
    IF (SELECT count(DISTINCT e ->> 'nature') <> count(*) FROM jsonb_array_elements(v_briques) e) THEN
        RETURN 'Une même brique deux fois dans une règle : réunissez-les en une';
    END IF;

    FOR b IN SELECT e FROM jsonb_array_elements(v_briques) e LOOP
        v_motif := motif_brique(b ->> 'nature', b ->> 'pour_qui',
                                (b ->> 'id_utilisateur')::INTEGER, b -> 'parametres');
        IF v_motif IS NOT NULL THEN
            RETURN v_motif;
        END IF;
    END LOOP;

    -- CND-7 : la période, et la fréquence qui ne vaut que pendant elle.
    IF p_validite IS NOT NULL
       AND (isempty(p_validite) OR lower_inf(p_validite) OR upper_inf(p_validite)) THEN
        RETURN 'Une période a un premier et un dernier jour';
    END IF;
    IF p_chaque_annee AND (p_validite IS NULL OR upper(p_validite) - lower(p_validite) > 366) THEN
        RETURN 'Une période qui revient chaque année dure moins d''un an';
    END IF;
    IF p_frequence IS NOT NULL THEN
        IF p_validite IS NULL THEN
            RETURN 'Changer la fréquence demande une période : du … au …';
        END IF;
        IF NOT t.recurrente THEN
            RETURN 'Une tâche qui ne revient pas d''elle-même n''a pas de fréquence';
        END IF;
        IF p_frequence ? 'fois' THEN
            IF COALESCE(p_frequence ->> 'par', '') NOT IN ('semaine', 'mois')
               OR (p_frequence ->> 'fois')::INTEGER NOT BETWEEN 1
                  AND (CASE (p_frequence ->> 'par') WHEN 'semaine' THEN 7 ELSE 31 END) THEN
                RETURN 'De 1 à 7 fois par semaine, ou de 1 à 31 fois par mois';
            END IF;
        ELSIF p_frequence ? 'min' THEN
            IF (p_frequence ->> 'min')::INTEGER < 1
               OR (p_frequence ->> 'max')::INTEGER < (p_frequence ->> 'min')::INTEGER THEN
                RETURN 'Tous les N à M jours, avec N au moins 1 et M au moins N';
            END IF;
        ELSE
            RETURN 'Une fréquence : tous les N à M jours, ou N fois par semaine ou par mois';
        END IF;
    END IF;

    -- CND-15 : ce que la tâche rend impossible.
    IF t.requiert_les_deux AND v_briques @> '[{"nature": "autre_absent"}]' THEN
        RETURN 'Une tâche à deux ne se fait pas quand l''autre est absent';
    END IF;
    SELECT e -> 'parametres' ->> 'partie' INTO v_partie
      FROM jsonb_array_elements(v_briques) e WHERE e ->> 'nature' = 'demi_journee';
    IF v_partie IS NOT NULL AND NOT t.rappel_journee
       AND ((v_partie = 'matin' AND t.heure_min >= '13:00')
            OR (v_partie = 'apres_midi' AND (t.heure_max <= '13:00' OR t.heure_min >= '19:00'))) THEN
        RETURN format('La tâche se fait entre %s et %s : hors de la demi-journée demandée',
                      to_char(t.heure_min, 'HH24hMI'), to_char(t.heure_max, 'HH24hMI'));
    END IF;

    RETURN NULL;
EXCEPTION WHEN invalid_text_representation OR numeric_value_out_of_range THEN
    RETURN 'Une fréquence illisible';
END $$;

COMMENT ON FUNCTION motif_regle(INTEGER, JSONB, DATERANGE, BOOLEAN, JSONB) IS
    'CND-1, CND-7, CND-15 : le motif du refus d''une règle pour cette tâche, ou rien.';

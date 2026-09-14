-- rejouable : ce fichier ne contient que des CREATE OR REPLACE et un DROP
--             conditionnel.
-- =============================================================================
-- 025 : « après les cours » ne veut pas dire « après le service »     (SPT-12)
--
-- La préférence « apres » démarre la séance à la fin des obligations du jour.
-- L'ancre comptait les cours et le travail. Un service qui finit à minuit
-- plaçait donc l'ancre à minuit, et aucun creux de la journée ne pouvait plus
-- l'accueillir : la salle et la course devenaient impossibles tous les jours
-- travaillés, sans que rien ne le dise.
--
-- Reproduit sur une semaine de cours 10h-11h30 et 15h30-17h30 avec un service
-- 19h15-minuit : zéro créneau pour la salle et la course, sept jours sur sept.
--
-- On va à la salle après les cours, pas après le service : le service est
-- justement ce qu'on a devant soi. L'ancre ne retient donc que les cours. Le
-- service continue d'occuper l'agenda, c'est le calcul des creux qui s'en
-- charge, et une séance ne peut toujours pas le chevaucher.
-- =============================================================================

CREATE OR REPLACE FUNCTION fin_des_cours(p_utilisateur INTEGER, p_jour DATE)
RETURNS TIMESTAMPTZ LANGUAGE sql STABLE AS $$
    SELECT max(LEAST(upper(o.periode), debut_jour(p_jour + 1)))
      FROM occupation o
     WHERE o.id_utilisateur = p_utilisateur
       AND o.type = 'cours'
       AND o.periode && tstzrange(debut_jour(p_jour), debut_jour(p_jour + 1), '[)');
$$;

COMMENT ON FUNCTION fin_des_cours IS
    'Fin du dernier cours de la journée, ou NULL si la journée n''en a aucun.
     Sert d''ancre à la préférence « apres » (SPT-12). Le travail en est exclu :
     un service du soir rendrait l''ancre inatteignable.';


-- -----------------------------------------------------------------------------
-- Recherche d'un créneau, avec la nouvelle ancre                        (SPT-12)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION creneaux_sport_du_jour(
    p_utilisateur INTEGER,
    p_tache       INTEGER,
    p_jour        DATE,
    p_duree       INTERVAL DEFAULT NULL
) RETURNS TABLE (
    id_lieu INTEGER,
    code    VARCHAR,
    libelle VARCHAR,
    rang    SMALLINT,
    creneau TSTZRANGE
) LANGUAGE plpgsql STABLE AS $$
DECLARE
    l        RECORD;
    v_plage  TSTZRANGE;
    v_dispo  TSTZRANGE;
    v_trajet INTERVAL;
    v_marge  INTERVAL;
    v_duree  INTERVAL;
    v_total  INTERVAL;
    v_ancre  TIMESTAMPTZ;
    v_debut  TIMESTAMPTZ;
    v_pris   BOOLEAN;
BEGIN
    -- SPT-6 : une seule séance par jour, et rien un jour d'absence.
    IF est_absent(p_utilisateur, p_jour)
       OR EXISTS (SELECT 1 FROM occurrence o
                    JOIN tache t ON t.id_tache = o.id_tache
                   WHERE o.id_utilisateur = p_utilisateur
                     AND t.categorie = 'sport'
                     AND o.creneau IS NOT NULL
                     AND jour_de(lower(o.creneau)) = p_jour
                     AND o.statut IN ('planifiee', 'notifiee')) THEN
        RETURN;
    END IF;

    FOR l IN SELECT ls.*, tl.rang AS preference_rang
               FROM tache_lieu tl
               JOIN lieu_sport ls ON ls.id_lieu = tl.id_lieu
              WHERE tl.id_tache = p_tache
              ORDER BY tl.rang, ls.id_lieu
    LOOP
        v_trajet := make_interval(
            mins => trajet_minutes(p_utilisateur, p_jour, l.id_lieu));
        v_marge  := make_interval(mins => l.marge_minutes);
        v_duree  := COALESCE(make_interval(mins => l.duree_minutes),
                             p_duree,
                             (SELECT make_interval(mins => duree_minutes)
                                FROM tache WHERE id_tache = p_tache));
        -- SPT-10 : la réservation englobe les marges. Le battement doit être
        -- libre, pas seulement souhaité.
        v_total := v_duree + 2 * v_trajet + 2 * v_marge;

        -- SPT-12 : l'ancre est la fin des cours, et d'eux seuls. Journée vide,
        -- pas d'ancre : on part à l'heure par défaut plutôt qu'au petit matin
        -- ou en soirée.
        v_ancre := fin_des_cours(p_utilisateur, p_jour);
        IF v_ancre IS NULL THEN
            v_ancre := (p_jour + l.heure_defaut) AT TIME ZONE 'Europe/Paris';
        END IF;

        v_pris := FALSE;

        FOR v_plage IN SELECT * FROM plages_ouvertes(l.id_lieu, p_jour) LOOP
            EXIT WHEN v_pris;

            -- Trajet et marge débordent de l'ouverture : on peut marcher, et
            -- attendre, avant que la piscine n'ouvre.
            v_plage := tstzrange(lower(v_plage) - v_trajet - v_marge,
                                 upper(v_plage) + v_trajet + v_marge, '[)')
                       * tstzrange(now(), NULL, '[)');
            CONTINUE WHEN isempty(v_plage);

            FOR v_dispo IN
                SELECT d FROM disponibilites(p_utilisateur,
                                             lower(v_plage), upper(v_plage)) d
                 ORDER BY CASE WHEN l.preference = 'tard' THEN lower(d) END DESC,
                          lower(d)
            LOOP
                CONTINUE WHEN upper(v_dispo) - lower(v_dispo) < v_total;

                v_debut := CASE l.preference
                    WHEN 'tard'  THEN upper(v_dispo) - v_total
                    -- On ne remonte jamais avant le début du creux, et on ne
                    -- descend jamais sous l'ancre : le premier moment tenable
                    -- après les cours.
                    WHEN 'apres' THEN GREATEST(lower(v_dispo), v_ancre)
                    ELSE lower(v_dispo)
                END;

                CONTINUE WHEN v_debut + v_total > upper(v_dispo);

                -- SPT-7 : le repos se juge sur la fin de la séance elle-même,
                -- marge et trajet du retour exclus.
                CONTINUE WHEN NOT repos_suffisant(
                    p_utilisateur, l.id_lieu,
                    v_debut + v_marge + v_trajet + v_duree);

                id_lieu := l.id_lieu;
                code    := l.code;
                libelle := l.libelle;
                rang    := l.preference_rang;
                creneau := tstzrange(v_debut, v_debut + v_total, '[)');
                RETURN NEXT;

                v_pris := TRUE;
                EXIT;
            END LOOP;
        END LOOP;
    END LOOP;
END $$;


-- L'ancienne ancre n'a plus d'appelant. La garder inviterait à s'en resservir.
DROP FUNCTION IF EXISTS fin_des_obligations(INTEGER, DATE);

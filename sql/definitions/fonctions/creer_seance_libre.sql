-- -----------------------------------------------------------------------------
-- Une séance libre : celle que le coach n'a pas écrite       (opération C13)
--                                         (LIB-1, LIB-3, LIB-5, LIB-11, SAI-9)
--
-- Annoncée d'avance, elle se pose au planning comme une séance posée à la
-- main : seuls un cours, un service ou ce qui est déjà annoncé l'interdisent.
-- Reconnue après coup ou ouverte sur le moment, elle ne prend pas de créneau :
-- elle garde seulement l'heure où elle a été faite.
--
-- Elle naît validée, et la même clé d'appareil renvoyée rend la même séance.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION creer_seance_libre(
    p_utilisateur INTEGER,
    p_discipline  VARCHAR,
    p_debut       TIMESTAMPTZ,
    p_duree       INTEGER DEFAULT 60,
    p_lieu        INTEGER DEFAULT NULL,
    p_annoncee    BOOLEAN DEFAULT FALSE,
    p_cle_client  UUID    DEFAULT NULL,
    p_type        VARCHAR DEFAULT 'libre'
) RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE
    v_tache      INTEGER;
    v_lieu       INTEGER := p_lieu;
    v_duree      INTEGER := LEAST(GREATEST(COALESCE(p_duree, 60), 15), 240);
    v_jour       DATE := jour_de(p_debut);
    v_bloc       TSTZRANGE;
    v_obstacle   TEXT;
    v_occurrence INTEGER;
BEGIN
    PERFORM exiger_coach(p_utilisateur);

    IF p_cle_client IS NOT NULL THEN
        SELECT se.id_occurrence INTO v_occurrence
          FROM seance se WHERE se.cle_client = p_cle_client;
        IF v_occurrence IS NOT NULL THEN
            RETURN v_occurrence;
        END IF;
    END IF;

    IF p_discipline NOT IN ('musculation', 'course', 'cardio') THEN
        PERFORM refus_coach('requete_invalide',
            'Une séance libre se fait en musculation, en course ou sur les machines cardio');
    END IF;

    SELECT t.id_tache INTO v_tache FROM tache t WHERE t.code = 'SPORT' AND t.active;
    IF v_tache IS NULL THEN
        PERFORM refus_coach('introuvable', 'Le sport est désactivé');
    END IF;

    -- Le lieu : celui donné, sinon le premier de la discipline s'il y en a un.
    IF v_lieu IS NULL THEN
        SELECT dl.id_lieu INTO v_lieu FROM discipline_lieu dl
         WHERE dl.id_utilisateur = p_utilisateur AND dl.discipline = p_discipline
         ORDER BY dl.rang LIMIT 1;
    END IF;

    IF p_annoncee AND p_debut > now() THEN
        v_obstacle := obstacle_seance_coach(p_utilisateur, v_lieu, p_debut, v_duree,
                                            p_discipline, NULL, FALSE);
        IF v_obstacle IS NOT NULL THEN
            PERFORM refus_coach('creneau_pris', v_obstacle);
        END IF;
        v_bloc := bloc_seance_duree(p_utilisateur, v_lieu, p_debut, v_duree);

        UPDATE occurrence o
           SET creneau = NULL, statut = 'a_placer',
               motif = 'Déplacée par une séance de sport'
         WHERE o.id_utilisateur = p_utilisateur
           AND o.statut = 'planifiee' AND NOT o.epinglee AND NOT o.rappel_journee
           AND o.origine NOT IN ('quota', 'coach')
           AND o.creneau && v_bloc;

        INSERT INTO occurrence (id_tache, id_utilisateur, fenetre, creneau, statut,
                                origine, epinglee, id_lieu, debut_seance, motif, titre)
        VALUES (v_tache, p_utilisateur,
                tstzrange(LEAST(debut_jour(v_jour), lower(v_bloc)),
                          GREATEST(debut_jour(v_jour + 1), upper(v_bloc)), '[)'),
                v_bloc, 'planifiee', 'manuelle', TRUE, v_lieu, p_debut,
                'Séance libre annoncée', titre_seance(p_discipline, 'validee', TRUE))
        RETURNING id_occurrence INTO v_occurrence;
    ELSE
        INSERT INTO occurrence (id_tache, id_utilisateur, fenetre, statut, origine,
                                id_lieu, debut_seance, motif, titre)
        VALUES (v_tache, p_utilisateur,
                tstzrange(LEAST(debut_jour(v_jour), p_debut),
                          GREATEST(debut_jour(v_jour + 1),
                                   p_debut + make_interval(mins => v_duree)), '[)'),
                'a_placer', 'manuelle', v_lieu, p_debut,
                'Séance libre', titre_seance(p_discipline, 'validee', TRUE))
        RETURNING id_occurrence INTO v_occurrence;
    END IF;

    INSERT INTO seance (id_occurrence, auteur, etat, libre, annoncee, discipline,
                        type_seance, duree_minutes, cle_client)
    VALUES (v_occurrence, 'utilisateur', 'validee', TRUE, COALESCE(p_annoncee, FALSE),
            p_discipline, left(COALESCE(p_type, 'libre'), 40), v_duree, p_cle_client);

    RETURN v_occurrence;
END $$;

COMMENT ON FUNCTION creer_seance_libre IS
    'Opération C13 : crée une séance libre, annoncée d''avance ou reconnue
     après coup. Elle naît validée. La même clé d''appareil rend la même séance
     (LIB-1, LIB-3, LIB-5, SAI-9).';

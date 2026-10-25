-- -----------------------------------------------------------------------------
-- Poser une séance à la main, ou la modifier                   (SPT-19, SPT-21)
--
-- Sert à la séance d'une invitation acceptée (SPT-31), et à celle qu'on pose
-- soi-même. Les règles sont souples : seuls un cours, un service ou ce qui est
-- déjà annoncé interdisent, et un jour porte au plus deux séances (SPT-37).
-- Ce qui était mobile sous la séance se replacera autour.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION choisir_seance_sport(
    p_utilisateur INTEGER,
    p_lieu        INTEGER,
    p_debut       TIMESTAMPTZ,
    p_occurrence  INTEGER DEFAULT NULL
) RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE
    v_tache      INTEGER;
    v_obstacle   TEXT;
    v_bloc       TSTZRANGE;
    v_jour       DATE := jour_de(p_debut);
    v_occurrence INTEGER;
BEGIN
    SELECT t.id_tache INTO v_tache FROM tache t WHERE t.id_type_tache IS NULL AND t.active;
    IF v_tache IS NULL THEN
        RAISE EXCEPTION 'Le sport est désactivé' USING ERRCODE = 'no_data_found';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM tache_lieu tl
                    WHERE tl.id_tache = v_tache AND tl.id_lieu = p_lieu) THEN
        RAISE EXCEPTION 'Sport inconnu' USING ERRCODE = 'no_data_found';
    END IF;

    IF p_occurrence IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM occurrence o
                        WHERE o.id_occurrence = p_occurrence
                          AND o.id_utilisateur = p_utilisateur
                          AND o.id_tache = v_tache
                          AND o.statut IN ('planifiee', 'notifiee')) THEN
        RAISE EXCEPTION 'Séance introuvable, ou déjà passée'
              USING ERRCODE = 'no_data_found';
    END IF;

    v_obstacle := obstacle_seance(p_utilisateur, p_lieu, p_debut, NULL, NULL,
                                  p_occurrence, FALSE);
    IF v_obstacle IS NOT NULL THEN
        RAISE EXCEPTION '%', v_obstacle USING ERRCODE = 'check_violation';
    END IF;

    v_bloc := bloc_de_seance(p_utilisateur, p_lieu, p_debut);

    UPDATE occurrence o
       SET creneau = NULL, statut = 'a_placer',
           motif = 'Déplacée par une séance de sport'
     WHERE o.id_utilisateur = p_utilisateur
       AND o.statut = 'planifiee'
       AND NOT o.epinglee
       AND NOT o.rappel_journee
       AND o.id_occurrence IS DISTINCT FROM p_occurrence
       AND o.creneau && v_bloc;

    IF p_occurrence IS NULL THEN
        INSERT INTO occurrence (id_tache, id_utilisateur, fenetre, creneau, statut,
                                origine, epinglee, id_lieu, debut_seance, motif)
        VALUES (v_tache, p_utilisateur,
                tstzrange(LEAST(debut_jour(v_jour), lower(v_bloc)),
                          GREATEST(debut_jour(v_jour + 1), upper(v_bloc)), '[)'),
                v_bloc, 'planifiee', 'manuelle', TRUE, p_lieu, p_debut, 'Choisie')
        RETURNING id_occurrence INTO v_occurrence;
    ELSE
        v_occurrence := p_occurrence;

        UPDATE occurrence o
           SET creneau      = v_bloc,
               fenetre      = tstzrange(LEAST(debut_jour(v_jour), lower(v_bloc)),
                                        GREATEST(debut_jour(v_jour + 1), upper(v_bloc)), '[)'),
               id_lieu      = p_lieu,
               debut_seance = p_debut,
               -- Déplacée à aujourd'hui, elle compte comme annoncée : la
               -- relance du soir doit la voir.
               statut       = CASE WHEN v_jour = jour_de(now()) THEN 'notifiee'
                                   ELSE 'planifiee' END,
               epinglee     = TRUE,
               motif        = 'Modifiée'
         WHERE o.id_occurrence = v_occurrence;
    END IF;

    RETURN v_occurrence;
END $$;

COMMENT ON FUNCTION choisir_seance_sport(INTEGER, INTEGER, TIMESTAMPTZ, INTEGER) IS
    'Pose une séance à la main, ou modifie celle donnée : lieu, jour, heure.
     Règles souples (SPT-19, SPT-21) ; sert à l''invitation acceptée (SPT-31).';

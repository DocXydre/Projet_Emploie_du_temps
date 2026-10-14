-- -----------------------------------------------------------------------------
-- Ce qui empêche une séance qui porte sa durée et sa discipline
--                                                     (PLN-5, SPT-34, SPT-37)
--
-- Même logique que obstacle_seance(), avec deux différences : la durée est
-- celle de la séance et non celle du lieu, et un jour porte jusqu'à deux
-- séances si leurs disciplines diffèrent.
--
--   Stricte, pour une proposition ou un ajustement du coach : le bloc entier
--   est libre, le lieu est ouvert, le repos est suffisant.
--
--   Souple, pour un geste de l'utilisateur : seuls un cours, un service ou ce
--   qui est déjà annoncé interdisent.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION obstacle_seance_coach(
    p_utilisateur INTEGER,
    p_lieu        INTEGER,
    p_debut       TIMESTAMPTZ,
    p_duree       INTEGER,
    p_discipline  VARCHAR,
    p_ignorer     INTEGER DEFAULT NULL,
    p_strict      BOOLEAN DEFAULT TRUE
) RETURNS TEXT LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_jour   DATE := jour_de(p_debut);
    v_bloc   TSTZRANGE;
    v_fin    TIMESTAMPTZ := p_debut + make_interval(mins => p_duree);
    v_raison TEXT;
    v_nombre INTEGER;
    v_meme   INTEGER;
BEGIN
    v_bloc := bloc_seance_duree(p_utilisateur, p_lieu, p_debut, p_duree);
    IF v_bloc IS NULL THEN
        RETURN 'Lieu inconnu';
    END IF;

    IF (p_strict AND lower(v_bloc) <= now()) OR p_debut <= now() THEN
        RETURN 'Ce moment est déjà passé';
    END IF;

    IF est_absent(p_utilisateur, v_jour) THEN
        RETURN 'Tu es absent ce jour-là';
    END IF;

    -- SPT-37 : deux séances par jour au plus, de disciplines différentes.
    SELECT count(*), count(*) FILTER (WHERE s.discipline = p_discipline)
      INTO v_nombre, v_meme
      FROM occurrence o
      JOIN tache t ON t.id_tache = o.id_tache
      LEFT JOIN seance s ON s.id_occurrence = o.id_occurrence
     WHERE o.id_utilisateur = p_utilisateur
       AND t.categorie = 'sport'
       AND o.origine <> 'quota'
       AND o.statut IN ('planifiee', 'notifiee', 'faite')
       AND o.id_occurrence IS DISTINCT FROM p_ignorer
       AND jour_de(COALESCE(o.debut_seance, lower(o.creneau), lower(o.fenetre))) = v_jour;
    IF v_meme > 0 THEN
        RETURN format('Une séance de %s est déjà prévue ce jour-là', p_discipline);
    END IF;
    IF v_nombre >= 2 THEN
        RETURN 'Deux séances sont déjà prévues ce jour-là';
    END IF;

    -- On ne se met pas en cours ni en service, même quand on choisit.
    SELECT format('Ça tombe sur « %s »', o.libelle) INTO v_raison
      FROM occupation o
     WHERE o.id_utilisateur = p_utilisateur
       AND o.type IN ('cours', 'travail')
       AND o.periode && v_bloc
     ORDER BY lower(o.periode)
     LIMIT 1;
    IF v_raison IS NOT NULL THEN
        RETURN v_raison;
    END IF;

    -- Ce qui est annoncé ou épinglé ne bouge plus (PLA-5), et une autre séance
    -- de sport, même seulement proposée, occupe son créneau (PLN-4).
    SELECT format('Ça tombe sur « %s »', COALESCE(o.titre, t.libelle)) INTO v_raison
      FROM occurrence o
      JOIN tache t ON t.id_tache = o.id_tache
     WHERE o.id_utilisateur = p_utilisateur
       AND o.creneau IS NOT NULL
       AND NOT o.rappel_journee
       AND o.statut IN ('planifiee', 'notifiee')
       AND o.origine <> 'quota'
       AND (o.epinglee OR o.statut = 'notifiee' OR t.categorie = 'sport')
       AND o.id_occurrence IS DISTINCT FROM p_ignorer
       AND o.creneau && v_bloc
     LIMIT 1;
    IF v_raison IS NOT NULL THEN
        RETURN v_raison;
    END IF;

    IF NOT p_strict THEN
        RETURN NULL;
    END IF;

    -- Le reste de l'agenda : rendez-vous, calendriers personnels.
    SELECT format('Ça tombe sur « %s »', o.libelle) INTO v_raison
      FROM occupation o
     WHERE o.id_utilisateur = p_utilisateur
       AND o.periode && v_bloc
     ORDER BY lower(o.periode)
     LIMIT 1;
    IF v_raison IS NOT NULL THEN
        RETURN v_raison;
    END IF;

    -- SPT-2 : la séance entière tient dans une plage ouverte.
    IF p_lieu IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM plages_ouvertes(p_lieu, v_jour) p
                        WHERE p @> tstzrange(p_debut, v_fin, '[)')) THEN
        RETURN 'Le lieu est fermé à cette heure-là';
    END IF;

    -- SPT-7 : une séance tardive laisse dormir avant la prochaine obligation.
    IF p_lieu IS NOT NULL AND NOT repos_suffisant(p_utilisateur, p_lieu, v_fin) THEN
        RETURN 'Trop tard : pas assez de repos avant le lendemain';
    END IF;

    RETURN NULL;
END $$;

COMMENT ON FUNCTION obstacle_seance_coach IS
    'Ce qui empêche une séance de cette durée et de cette discipline à cette
     heure, ou NULL. Stricte pour le coach, souple pour l''utilisateur
     (PLN-5, SPT-34, SPT-37).';

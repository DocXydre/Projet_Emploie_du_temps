-- -----------------------------------------------------------------------------
-- Ce qui empêche une séance                                    (SPT-19, SPT-21)
--
-- Rend la raison, ou NULL si rien n'empêche. Deux sévérités.
--
--   Stricte, pour ce que le système propose : le lieu est ouvert, le bloc
--   entier est libre, le repos est suffisant. Une proposition ne se fait que
--   si elle tient complètement.
--
--   Souple, pour ce qu'on choisit soi-même : seules les obligations comptent.
--   On sait parfois mieux que le moteur (SPT-17), mais on ne se met pas en
--   cours ni en service.
--
-- Les réservations « à déterminer » sont ignorées : elles sont là pour céder la
-- place à une vraie séance. Les tâches encore mobiles aussi : une séance passe
-- avant le ménage, qui se replace autour.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION obstacle_seance(
    p_utilisateur INTEGER,
    p_lieu        INTEGER,
    p_debut       TIMESTAMPTZ,
    p_ignorer     INTEGER DEFAULT NULL,
    p_strict      BOOLEAN DEFAULT TRUE
) RETURNS TEXT LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_jour   DATE := jour_de(p_debut);
    v_bloc   TSTZRANGE;
    v_duree  INTERVAL;
    v_raison TEXT;
BEGIN
    v_bloc  := bloc_de_seance(p_utilisateur, p_lieu, p_debut);
    v_duree := duree_seance(p_lieu);

    IF v_bloc IS NULL THEN
        RETURN 'Sport inconnu';
    END IF;

    -- Une proposition doit laisser le temps d'y aller ; un choix, seulement ne
    -- pas être déjà commencé.
    IF (p_strict AND lower(v_bloc) <= now()) OR p_debut <= now() THEN
        RETURN 'Ce moment est déjà passé';
    END IF;

    IF est_absent(p_utilisateur, v_jour) THEN
        RETURN 'Tu es absent ce jour-là';
    END IF;

    -- SPT-6 : une séance par jour.
    IF EXISTS (
        SELECT 1 FROM occurrence o
          JOIN tache t ON t.id_tache = o.id_tache
         WHERE o.id_utilisateur = p_utilisateur
           AND t.categorie = 'sport'
           AND o.origine <> 'quota'
           AND o.statut IN ('planifiee', 'notifiee', 'faite')
           AND o.id_occurrence IS DISTINCT FROM p_ignorer
           AND jour_de(COALESCE(o.debut_seance, lower(o.creneau))) = v_jour
    ) THEN
        RETURN 'Une séance est déjà prévue ce jour-là';
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

    -- Ce qui a été annoncé ou épinglé ne bouge plus (PLA-5) : une séance ne
    -- peut pas le recouvrir, choisie ou non.
    SELECT format('Ça tombe sur « %s »', t.libelle) INTO v_raison
      FROM occurrence o
      JOIN tache t ON t.id_tache = o.id_tache
     WHERE o.id_utilisateur = p_utilisateur
       AND o.creneau IS NOT NULL
       AND NOT o.rappel_journee
       AND o.statut IN ('planifiee', 'notifiee')
       AND o.origine <> 'quota'
       AND (o.epinglee OR o.statut = 'notifiee')
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
    IF NOT EXISTS (SELECT 1 FROM plages_ouvertes(p_lieu, v_jour) p
                    WHERE p @> tstzrange(p_debut, p_debut + v_duree, '[)')) THEN
        RETURN 'Le lieu est fermé à cette heure-là';
    END IF;

    -- SPT-7 : une séance tardive laisse dormir avant la prochaine obligation.
    IF NOT repos_suffisant(p_utilisateur, p_lieu, p_debut + v_duree) THEN
        RETURN 'Trop tard : pas assez de repos avant le lendemain';
    END IF;

    RETURN NULL;
END $$;

COMMENT ON FUNCTION obstacle_seance IS
    'Ce qui empêche une séance de ce sport à cette heure, ou NULL. Stricte pour
     les propositions, souple pour un choix (SPT-19, SPT-21).';

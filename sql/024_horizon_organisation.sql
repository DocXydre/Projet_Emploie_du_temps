-- rejouable : ce fichier ne contient que des CREATE OR REPLACE.
-- =============================================================================
-- 024 : jusqu'où l'on peut organiser son sport                       (SPT-16)
--
-- Organiser ne portait que sur la semaine en cours. Un lundi c'est le bon
-- cadrage, un vendredi il ne reste presque rien à caser et la commande ne sert
-- plus à rien.
--
-- La semaine suivante est donc toujours ouverte, et une troisième s'ouvre à
-- partir du jeudi : avant, l'emploi du temps de cette semaine-là n'est pas
-- assez sûr pour qu'on s'engage dessus.
-- =============================================================================

CREATE OR REPLACE FUNCTION semaines_ouvertes(p_jour DATE DEFAULT NULL)
RETURNS SMALLINT LANGUAGE sql STABLE AS $$
    -- ISODOW : 1 = lundi, 4 = jeudi.
    SELECT CASE WHEN EXTRACT(ISODOW FROM COALESCE(p_jour, jour_de(now()))) >= 4
                THEN 3::SMALLINT
                ELSE 2::SMALLINT END;
$$;

COMMENT ON FUNCTION semaines_ouvertes IS
    'Nombre de semaines organisables, la semaine en cours comprise. Deux du
     lundi au mercredi, trois à partir du jeudi (SPT-16).';


-- -----------------------------------------------------------------------------
-- Les créneaux de toutes les semaines ouvertes                          (SPT-16)
--
-- `creneaux_sport_semaine` garde sa portée d'une semaine : elle reste utile
-- telle quelle, et c'est elle qu'on appelle ici semaine après semaine.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION creneaux_sport_horizon(
    p_utilisateur INTEGER,
    p_jour        DATE DEFAULT NULL
) RETURNS TABLE (
    lundi   DATE,
    jour    DATE,
    id_lieu INTEGER,
    code    VARCHAR,
    libelle VARCHAR,
    rang    SMALLINT,
    creneau TSTZRANGE
) LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_jour     DATE     := COALESCE(p_jour, jour_de(now()));
    v_lundi    DATE     := lundi_de(v_jour);
    v_semaines SMALLINT := semaines_ouvertes(v_jour);
    i          INTEGER  := 0;
BEGIN
    WHILE i < v_semaines LOOP
        RETURN QUERY
        SELECT v_lundi + (i * 7), c.jour, c.id_lieu, c.code, c.libelle,
               c.rang, c.creneau
          FROM creneaux_sport_semaine(p_utilisateur, v_lundi + (i * 7)) c;
        i := i + 1;
    END LOOP;
END $$;


-- -----------------------------------------------------------------------------
-- Ce qu'il reste à caser sur l'horizon ouvert                           (SPT-16)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION seances_sport_a_caser(
    p_utilisateur INTEGER,
    p_jour        DATE DEFAULT NULL
) RETURNS INTEGER LANGUAGE sql STABLE AS $$
    SELECT COALESCE(sum(
               seances_sport_restantes(
                   p_utilisateur,
                   lundi_de(COALESCE(p_jour, jour_de(now()))) + (n * 7))
           ), 0)::INTEGER
      FROM generate_series(
               0,
               semaines_ouvertes(COALESCE(p_jour, jour_de(now()))) - 1) AS n;
$$;

COMMENT ON FUNCTION seances_sport_a_caser IS
    'Séances encore à caser sur toutes les semaines ouvertes, et non sur la
     seule semaine en cours (SPT-16).';

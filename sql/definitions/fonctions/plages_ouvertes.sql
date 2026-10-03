-- -----------------------------------------------------------------------------
-- Plages ouvertes un jour donné                                           (SPT-2)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION plages_ouvertes(p_lieu INTEGER, p_jour DATE)
RETURNS SETOF TSTZRANGE LANGUAGE sql STABLE AS $$
    WITH bornes AS (
        -- SPT-3 : un lieu fermé ce jour-là n'a aucune plage, quelles que soient
        -- ses heures habituelles.
        SELECT l.heure_min, l.heure_max
          FROM lieu_sport l
         WHERE l.id_lieu = p_lieu
           AND NOT EXISTS (SELECT 1 FROM fermeture f
                            WHERE f.id_lieu = p_lieu
                              AND f.periode @> p_jour)
    ),
    declarees AS (
        SELECT tstzrange((p_jour + o.heure_debut) AT TIME ZONE 'Europe/Paris',
                         (p_jour + o.heure_fin)   AT TIME ZONE 'Europe/Paris',
                         '[)') AS plage
          FROM ouverture o
         WHERE o.id_lieu = p_lieu
           AND o.jour_semaine = EXTRACT(ISODOW FROM p_jour)::SMALLINT
    ),
    -- Un lieu qui n'a AUCUN horaire déclaré est ouvert en permanence : c'est
    -- la salle, et cela évite d'écrire sept lignes pour dire « toujours ».
    --
    -- La nuance porte tout : « aucune plage ce jour-là » n'est pas « ouvert
    -- en permanence ». La piscine n'ayant rien le dimanche, la première
    -- version proposait un bain à 6h40 devant une porte close.
    toutes AS (
        SELECT plage FROM declarees
        UNION ALL
        SELECT tstzrange((p_jour + b.heure_min) AT TIME ZONE 'Europe/Paris',
                         (p_jour + b.heure_max) AT TIME ZONE 'Europe/Paris',
                         '[)')
          FROM bornes b
         WHERE NOT EXISTS (SELECT 1 FROM ouverture o WHERE o.id_lieu = p_lieu)
    )
    SELECT t.plage
             * tstzrange((p_jour + b.heure_min) AT TIME ZONE 'Europe/Paris',
                         (p_jour + b.heure_max) AT TIME ZONE 'Europe/Paris', '[)')
      FROM toutes t, bornes b
     WHERE NOT isempty(
               t.plage * tstzrange((p_jour + b.heure_min) AT TIME ZONE 'Europe/Paris',
                                   (p_jour + b.heure_max) AT TIME ZONE 'Europe/Paris', '[)'))
     ORDER BY 1;
$$;

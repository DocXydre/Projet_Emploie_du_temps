CREATE VIEW v_conflit AS
SELECT
    c.id_conflit,
    c.statut,
    c.choix,
    c.motif_caducite,
    c.date_detection,
    s.code                        AS source,

    -- Ce qui est déjà au planning.
    o.id_occupation,
    o.libelle                     AS libelle_existante,
    lower(o.periode)              AS debut_existante,
    upper(o.periode)              AS fin_existante,
    o.lieu                        AS lieu_existante,

    -- Ce que la source voudrait mettre à la place.
    c.libelle                     AS libelle_nouvelle,
    lower(c.periode)              AS debut_nouvelle,
    upper(c.periode)              AS fin_nouvelle,
    c.lieu                        AS lieu_nouvelle,
    c.details                     AS details_nouvelle,

    -- COL-11 : au-delà de deux semaines, on ne dérange pas. L'emploi du temps a
    -- toutes les chances d'être corrigé d'ici là.
    -- COL-19 : en deçà de maintenant, il n'y a plus rien à décider.
    (    lower(c.periode) >  now()
     AND lower(c.periode) <= now() + INTERVAL '14 days') AS a_arbitrer,
    EXTRACT(DAY FROM lower(c.periode) - now())::INTEGER AS dans_combien_de_jours
FROM conflit c
JOIN occupation o ON o.id_occupation = c.id_occupation
JOIN source s     ON s.id_source = c.id_source;

COMMENT ON VIEW v_conflit IS
    'Les deux versions côte à côte, pour que le bot puisse poser la question
     sans que le client ait à recalculer quoi que ce soit. Seul un conflit à
     venir, et à moins de deux semaines, est à arbitrer.';

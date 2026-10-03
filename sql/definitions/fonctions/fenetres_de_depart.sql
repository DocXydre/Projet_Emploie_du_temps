-- -----------------------------------------------------------------------------
-- Fenêtres de départ                                                 (TRJ-1, TRJ-2)
--
-- Un creux d'au moins N heures sans cours ni travail. Le sommeil ne compte
-- pas, et les absences déjà déclarées sont retirées.
--
-- L'arithmétique des multirange donne les bornes : un creux commence quand
-- finit l'obligation qui le précède. Les colonnes valent NULL au bord de
-- l'horizon, où il n'y a pas d'obligation à signaler.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fenetres_de_depart(
    p_utilisateur   INTEGER,
    p_debut         TIMESTAMPTZ,
    p_fin           TIMESTAMPTZ,
    p_duree_heures  INTEGER DEFAULT 48,
    p_marge_minutes INTEGER DEFAULT 30
) RETURNS TABLE (
    debut                 TIMESTAMPTZ,
    fin                   TIMESTAMPTZ,
    duree                 INTERVAL,
    fin_obligation_avant  TIMESTAMPTZ,
    debut_obligation_apres TIMESTAMPTZ,
    depart_au_plus_tot    TIMESTAMPTZ,
    retour_au_plus_tard   TIMESTAMPTZ
) LANGUAGE sql STABLE AS $$
    WITH horizon AS (
        SELECT tstzrange(greatest(p_debut, now()), p_fin, '[)') AS plage
    ),
    pris AS (
        -- Seuls les cours et le travail retiennent sur place. Une tâche
        -- ménagère, elle, se replace : ce n'est pas une raison de ne pas
        -- partir, c'est justement ce que l'absence résout.
        SELECT o.periode AS plage
          FROM occupation o, horizon h
         WHERE o.id_utilisateur = p_utilisateur
           AND o.type IN ('cours', 'travail')
           AND o.periode && h.plage

        UNION ALL

        SELECT a.periode
          FROM absence a, horizon h
         WHERE a.id_utilisateur = p_utilisateur
           AND a.periode && h.plage
    ),
    creux AS (
        SELECT unnest(
            tstzmultirange((SELECT plage FROM horizon))
            - COALESCE((SELECT range_agg(plage) FROM pris), '{}'::TSTZMULTIRANGE)
        ) AS plage
    )
    SELECT lower(c.plage),
           upper(c.plage),
           upper(c.plage) - lower(c.plage),
           -- Le bord de l'horizon n'est pas une obligation : ne rien affirmer
           -- vaut mieux qu'affirmer faux.
           CASE WHEN lower(c.plage) > (SELECT lower(plage) FROM horizon)
                THEN lower(c.plage) END,
           CASE WHEN upper(c.plage) < p_fin THEN upper(c.plage) END,
           -- TRJ-2 : le temps d'aller à la gare.
           CASE WHEN lower(c.plage) > (SELECT lower(plage) FROM horizon)
                THEN lower(c.plage) + make_interval(mins => p_marge_minutes)
                ELSE lower(c.plage) END,
           CASE WHEN upper(c.plage) < p_fin
                THEN upper(c.plage) - make_interval(mins => p_marge_minutes)
                ELSE upper(c.plage) END
      FROM creux c
     WHERE upper(c.plage) - lower(c.plage) >= make_interval(hours => p_duree_heures)
     ORDER BY lower(c.plage);
$$;

COMMENT ON FUNCTION fenetres_de_depart IS
    'Creux d''au moins N heures sans cours ni travail, avec les bornes '
    'utilisables pour chercher un train (TRJ-1, TRJ-2).';

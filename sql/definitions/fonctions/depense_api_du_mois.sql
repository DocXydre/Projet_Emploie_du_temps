-- -----------------------------------------------------------------------------
-- Ce que l'API a coûté ce mois-ci à un compte, en dollars          (FOU-7)
--
-- Sur les appels passés par son fournisseur « api » depuis le premier du mois,
-- heure de Paris. Les tokens d'entrée comptent tout ce que le modèle a lu
-- (COA-21) : on en retire la part relue depuis le cache et celle qui y a été
-- écrite, comptées chacune à leur tarif. Un modèle absent de la grille est
-- compté au tarif le plus cher : le plafond reste prudent.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION depense_api_du_mois(p_utilisateur INTEGER)
RETURNS NUMERIC LANGUAGE sql STABLE AS $$
    WITH plus_cher AS (
        SELECT max(entree) AS entree, max(cache_lu) AS cache_lu,
               max(cache_ecrit) AS cache_ecrit, max(sortie) AS sortie
          FROM tarif_modele
    )
    SELECT COALESCE(round(sum(
               (a.tokens_entree - a.tokens_cache - a.tokens_cache_ecrit)
                   * COALESCE(t.entree, p.entree)
             + a.tokens_cache * COALESCE(t.cache_lu, p.cache_lu)
             + a.tokens_cache_ecrit * COALESCE(t.cache_ecrit, p.cache_ecrit)
             + a.tokens_sortie * COALESCE(t.sortie, p.sortie)
           ) / 1000000.0, 4), 0)
      FROM appel_coach a
      CROSS JOIN plus_cher p
      LEFT JOIN tarif_modele t ON t.modele = a.modele
     WHERE a.id_utilisateur = p_utilisateur
       AND a.fournisseur = 'api'
       AND a.debut >= (date_trunc('month', now() AT TIME ZONE 'Europe/Paris')
                       AT TIME ZONE 'Europe/Paris');
$$;

COMMENT ON FUNCTION depense_api_du_mois(INTEGER) IS
    'FOU-7 : la dépense du mois passée par l''API, d''après les tokens de chaque
     appel et la grille des tarifs.';

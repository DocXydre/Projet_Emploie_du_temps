-- -----------------------------------------------------------------------------
-- Repérer les week-ends libres                                       (WKD-1, WKD-4)
--
-- On cherche les fenêtres au-delà du délai demandé, puis on filtre. Sinon une
-- fenêtre à cheval sur l'horizon est tronquée et perd sa durée minimale.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION proposer_weekends(
    p_utilisateur  INTEGER,
    p_lieu         VARCHAR DEFAULT NULL,
    p_delai_jours  INTEGER DEFAULT 14,
    p_duree_heures INTEGER DEFAULT 48
) RETURNS SETOF proposition LANGUAGE plpgsql AS $$
BEGIN
    PERFORM entretenir_propositions();

    RETURN QUERY
    INSERT INTO proposition (id_utilisateur, periode, lieu)
    SELECT p_utilisateur, tstzrange(f.debut, f.fin, '[)'), p_lieu
      FROM fenetres_de_depart(p_utilisateur, now(),
                              now() + make_interval(days => p_delai_jours + 10),
                              p_duree_heures) f
     WHERE f.debut <= now() + make_interval(days => p_delai_jours)
       -- Ni déjà proposé, ni déjà refusé : revenir à la charge sur un week-end
       -- qu'on a décliné est le meilleur moyen de faire couper les alertes.
       AND NOT EXISTS (
           SELECT 1 FROM proposition p
            WHERE p.id_utilisateur = p_utilisateur
              AND p.periode && tstzrange(f.debut, f.fin, '[)')
              AND p.statut <> 'perimee')
       -- Ni déjà parti : une absence déclarée vaut réponse.
       AND NOT EXISTS (
           SELECT 1 FROM absence a
            WHERE a.id_utilisateur = p_utilisateur
              AND a.periode && tstzrange(f.debut, f.fin, '[)'))
    RETURNING *;
END $$;

COMMENT ON FUNCTION proposer_weekends IS
    'Crée une proposition par creux assez long commençant dans le délai donné.
     Idempotente : rejouée le lendemain, elle ne crée rien de nouveau (WKD-2).';

-- -----------------------------------------------------------------------------
-- Renouvellement                                                          (UTI-3)
-- -----------------------------------------------------------------------------
-- Révoquer, c'est remplacer. Les abonnements existants cessent aussitôt de
-- fonctionner, ce qui est précisément l'effet recherché.
CREATE OR REPLACE FUNCTION renouveler_jeton_calendrier(p_utilisateur INTEGER)
RETURNS VARCHAR LANGUAGE sql AS $$
    UPDATE utilisateur
       SET jeton_calendrier = replace(gen_random_uuid()::TEXT, '-', '')
     WHERE id_utilisateur = p_utilisateur AND actif
    RETURNING jeton_calendrier;
$$;

COMMENT ON FUNCTION renouveler_jeton_calendrier IS
    'Invalide l''abonnement calendrier en place et en rend un nouveau (UTI-3).';

CREATE OR REPLACE FUNCTION assigner_calendriers_perso() RETURNS INTEGER
LANGUAGE plpgsql AS $$
DECLARE
    v_touchees INTEGER;
BEGIN
    -- Une expression régulière et non un LIKE : dans un motif LIKE, le tiret
    -- bas est un joker, « PERSO_LORETTE_% » accepterait donc PERSO_LORETTEX.
    UPDATE source s
       SET id_utilisateur = u.id_utilisateur
      FROM utilisateur u
     WHERE s.code ~ ('^PERSO_' || upper(u.pseudo) || '(_|$)')
       AND s.id_utilisateur IS DISTINCT FROM u.id_utilisateur;

    GET DIAGNOSTICS v_touchees = ROW_COUNT;
    RETURN v_touchees;
END $$;

COMMENT ON FUNCTION assigner_calendriers_perso() IS
    'Rattache PERSO_<PSEUDO> et PERSO_<PSEUDO>_<QUOI> à leur propriétaire. À
     exécuter avant appliquer_assignations(), qui donnerait sinon toute source
     orpheline à l''administrateur.';

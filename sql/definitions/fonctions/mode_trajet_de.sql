-- -----------------------------------------------------------------------------
-- Le mode de trajet d'un compte vers un lieu                           (ADR-7)
--
-- Celui qu'il a dit. Sinon, à pied jusqu'à 2 km du foyer à vol d'oiseau, en
-- voiture au-delà ; sans adresse du foyer, à pied.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION mode_trajet_de(p_utilisateur INTEGER, p_lieu INTEGER)
RETURNS VARCHAR LANGUAGE sql STABLE AS $$
    SELECT COALESCE(
        (SELECT c.mode_trajet FROM lieu_de_chacun c
          WHERE c.id_utilisateur = p_utilisateur AND c.id_lieu_connu = p_lieu),
        (SELECT CASE WHEN distance_m(f.latitude, f.longitude, l.latitude, l.longitude) > 2000
                     THEN 'voiture' ELSE 'pied' END
           FROM lieu_connu l, lieu_connu f
          WHERE l.id_lieu_connu = p_lieu
            AND f.id_lieu_connu = lieu_du_foyer(p_utilisateur)),
        'pied');
$$;

COMMENT ON FUNCTION mode_trajet_de(INTEGER, INTEGER) IS
    'ADR-7 : le mode dit pour ce lieu, ou à pied jusqu''à 2 km du foyer, en voiture au-delà.';

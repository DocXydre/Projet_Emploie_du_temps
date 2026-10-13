-- -----------------------------------------------------------------------------
-- Les places encore libres dans un foyer                                 (FOY-4)
--
-- Deux personnes au plus dans cette version : les règles du ménage sont écrites
-- pour deux. Une invitation encore valable réserve sa place.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION places_libres(p_foyer INTEGER)
RETURNS INTEGER LANGUAGE sql STABLE AS $$
    SELECT 2
         - (SELECT count(*) FROM utilisateur WHERE id_foyer = p_foyer AND actif)::INTEGER
         - (SELECT count(*) FROM invitation
             WHERE id_foyer = p_foyer AND servie_le IS NULL AND annulee_le IS NULL
               AND expire_le > now())::INTEGER
$$;

COMMENT ON FUNCTION places_libres(INTEGER) IS
    'FOY-4 : deux places par foyer, moins les membres et les invitations encore valables.';

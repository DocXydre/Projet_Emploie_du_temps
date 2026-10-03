-- -----------------------------------------------------------------------------
-- Périmer ce qui est derrière nous.                                    (COL-19)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION perimer_les_conflits() RETURNS INTEGER
LANGUAGE plpgsql AS $$
DECLARE
    v_nombre INTEGER;
BEGIN
    UPDATE conflit
       SET statut          = 'caduc',
           motif_caducite  = 'passe',
           date_resolution = now()
     WHERE statut = 'en_attente'
       AND lower(periode) <= now();

    GET DIAGNOSTICS v_nombre = ROW_COUNT;
    RETURN v_nombre;
END $$;

COMMENT ON FUNCTION perimer_les_conflits IS
    'Ferme les conflits dont la période a commencé : la question ne se pose
     plus, et une liste qui grossit sans fin ne se lit pas.';

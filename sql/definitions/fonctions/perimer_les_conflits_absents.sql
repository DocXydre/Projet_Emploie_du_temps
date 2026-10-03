-- -----------------------------------------------------------------------------
-- Périmer ce que la source ne propose plus.                            (COL-20)
--
-- Appelée en fin de collecte avec les clés des séances qui se sont réellement
-- heurtées à une occupation existante. Toute autre question en attente pour
-- cette source n'a plus d'objet : la séance a été filtrée (groupe de TD, UE
-- écartée), retirée du flux, ou elle ne chevauche plus rien.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION perimer_les_conflits_absents(
    p_source INTEGER,
    p_cles   TEXT[]
) RETURNS INTEGER
LANGUAGE plpgsql AS $$
DECLARE
    v_nombre INTEGER;
BEGIN
    UPDATE conflit
       SET statut          = 'caduc',
           motif_caducite  = 'sans_objet',
           date_resolution = now()
     WHERE id_source = p_source
       AND statut    = 'en_attente'
       AND lower(periode) > now()
       -- Un conflit ne s'enregistre qu'à moins de deux semaines (COL-11) :
       -- au-delà, l'absence de la clé ne prouve rien, la collecte peut
       -- simplement n'être pas allée jusque-là.
       AND lower(periode) <= now() + INTERVAL '14 days'
       AND NOT (cle_externe = ANY(COALESCE(p_cles, ARRAY[]::TEXT[])));

    GET DIAGNOSTICS v_nombre = ROW_COUNT;
    RETURN v_nombre;
END $$;

COMMENT ON FUNCTION perimer_les_conflits_absents IS
    'Ferme les conflits qu''une collecte ne reproduit plus : choisir un groupe
     ou écarter une UE règle le conflit aussi sûrement qu''un arbitrage.';

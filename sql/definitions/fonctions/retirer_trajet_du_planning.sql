CREATE OR REPLACE FUNCTION retirer_trajet_du_planning(p_trajet BIGINT)
RETURNS INTEGER LANGUAGE sql AS $$
    WITH parties AS (
        DELETE FROM occupation
         WHERE cle_externe = format('trajet-%s', p_trajet)
           AND id_source = (SELECT id_source FROM source WHERE code = 'MANUELLE')
        RETURNING 1)
    SELECT count(*)::INTEGER FROM parties;
$$;

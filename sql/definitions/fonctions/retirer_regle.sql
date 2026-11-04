CREATE OR REPLACE FUNCTION retirer_regle(p_regle BIGINT) RETURNS BOOLEAN
LANGUAGE plpgsql AS $$
BEGIN
  UPDATE regle SET etat = 'retiree', retiree_le = now(), motif_echec = NULL 
  WHERE id_regle = p_regle AND sorte IS NOT NULL AND etat <> 'retiree';
  
  RETURN FOUND;
END $$;

COMMENT ON FUNCTION retirer_regle(BIGINT) IS 'RGL-9, RGL-10 : retire une règle typée sans l''effacer. Faux si elle n''existe pas, est déjà retirée, ou n''est pas typée.';

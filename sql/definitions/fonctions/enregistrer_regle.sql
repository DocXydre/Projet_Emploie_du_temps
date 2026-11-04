CREATE OR REPLACE FUNCTION enregistrer_regle(p_tache INTEGER, p_sorte TEXT, p_parametres JSONB, p_phrase TEXT, p_dite_par INTEGER, p_appel BIGINT DEFAULT NULL) RETURNS BIGINT
LANGUAGE plpgsql AS $$
DECLARE
  v_phrase TEXT := btrim(COALESCE(p_phrase, ''));
  v_parametres JSONB := COALESCE(p_parametres, '{}'::jsonb);
  v_sorte sorte_regle;
  v_avant regle;
  v_existe BOOLEAN;
  v_id BIGINT;
  v_nom TEXT;
  v_def JSONB;
  v_val JSONB;
  v_nombre NUMERIC;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM tache WHERE id_tache = p_tache AND id_type_tache IS NOT NULL) THEN
    PERFORM refus_coach('introuvable', 'Cette tâche n''existe pas');
  END IF;

  SELECT * INTO v_sorte FROM sorte_regle WHERE code = p_sorte AND cible = 'tache';
  IF NOT FOUND THEN
    PERFORM refus_coach('sorte_inconnue', format('« %s » n''est pas une sorte de règle de tâche : lis lire_regles', p_sorte));
  END IF;

  IF v_phrase = '' OR length(v_phrase) > 500 THEN
    PERFORM refus_coach('phrase_invalide', 'La phrase de la règle tient en 1 à 500 caractères : ce que la personne a dit');
  END IF;

  IF jsonb_typeof(v_parametres) <> 'object' THEN
    PERFORM refus_coach('parametres_invalides', 'Les paramètres sont un objet');
  END IF;

  FOR v_nom IN SELECT k FROM jsonb_object_keys(v_parametres) AS k
  LOOP
    IF NOT (v_sorte.parametres ? v_nom) THEN
      PERFORM refus_coach('parametres_invalides', format('Paramètre « %s » inconnu pour la sorte %s', v_nom, p_sorte));
    END IF;
  END LOOP;

  FOR v_nom, v_def IN SELECT key, value FROM jsonb_each(v_sorte.parametres)
  LOOP
    IF NOT (v_parametres ? v_nom) THEN
      PERFORM refus_coach('parametres_invalides', format('Il manque le paramètre « %s »', v_nom));
    END IF;
    
    v_val := v_parametres -> v_nom;
    
    IF v_def->>'type' = 'integer' THEN
      IF jsonb_typeof(v_val) <> 'number' THEN
        PERFORM refus_coach('parametres_invalides', format('Le paramètre « %s » est un nombre entier', v_nom));
      ELSE
        v_nombre := (v_val #>> '{}')::numeric;
        IF v_nombre <> trunc(v_nombre) THEN
          PERFORM refus_coach('parametres_invalides', format('Le paramètre « %s » est un nombre entier', v_nom));
        END IF;
        
        IF v_nombre < (v_def->>'minimum')::numeric OR v_nombre > (v_def->>'maximum')::numeric THEN
          PERFORM refus_coach('parametres_invalides', format('Le paramètre « %s » vaut entre %s et %s', v_nom, v_def->>'minimum', v_def->>'maximum'));
        END IF;
      END IF;
    END IF;
  END LOOP;

  SELECT * INTO v_avant FROM regle WHERE id_tache = p_tache AND sorte = p_sorte AND etat <> 'retiree' ORDER BY id_regle DESC LIMIT 1;
  v_existe := FOUND;

  IF v_existe AND v_avant.parametres = v_parametres AND v_avant.phrase = v_phrase THEN
    RETURN v_avant.id_regle;
  END IF;

  INSERT INTO regle (id_tache, sorte, parametres, phrase, dite_par, id_appel) 
  VALUES (p_tache, p_sorte, v_parametres, v_phrase, p_dite_par, p_appel) 
  RETURNING id_regle INTO v_id;

  IF v_existe THEN
    UPDATE regle SET etat = 'retiree', retiree_le = now(), motif_echec = NULL, remplacee_par = v_id 
    WHERE id_regle = v_avant.id_regle;
  END IF;

  RETURN v_id;
END $$;

COMMENT ON FUNCTION enregistrer_regle(INTEGER, TEXT, JSONB, TEXT, INTEGER, BIGINT) IS 'RGL-2, RGL-10 : enregistre une règle typée sur une tâche après avoir vérifié sa sorte et ses paramètres ; une règle de même sorte en vigueur est gardée, retirée et renvoyée à la nouvelle.';

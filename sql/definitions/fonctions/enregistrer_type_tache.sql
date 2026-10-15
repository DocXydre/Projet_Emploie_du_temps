-- -----------------------------------------------------------------------------
-- Créer ou modifier un type de tâche                            (TAC-25, TAC-26)
--
-- Sans numéro, le type est créé ; avec, il est modifié, et ce qui n'est pas
-- donné reste tel quel. Un type d'origine garde sa famille : renommer « Chat »
-- en « Sassy » ne doit pas faire sortir la litière des soins du chat.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION enregistrer_type_tache(p_type          INTEGER,
                                                  p_libelle       TEXT,
                                                  p_couleur       TEXT,
                                                  p_icone         TEXT,
                                                  p_duree_minutes INTEGER,
                                                  p_priorite      INTEGER)
RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE
    v_libelle TEXT := NULLIF(btrim(regexp_replace(COALESCE(p_libelle, ''), '\s+', ' ', 'g')), '');
    v_type    INTEGER;
BEGIN
    IF p_type IS NULL AND (v_libelle IS NULL OR p_couleur IS NULL) THEN
        RAISE EXCEPTION 'Un type a un nom et une couleur'
              USING ERRCODE = 'check_violation';
    END IF;
    IF p_type IS NOT NULL AND NOT EXISTS (SELECT 1 FROM type_tache WHERE id_type_tache = p_type) THEN
        RAISE EXCEPTION 'Ce type de tâche n''existe pas' USING ERRCODE = 'no_data_found';
    END IF;
    IF v_libelle IS NOT NULL AND length(v_libelle) > 40 THEN
        RAISE EXCEPTION 'Le nom d''un type fait 40 caractères au plus'
              USING ERRCODE = 'check_violation';
    END IF;
    IF v_libelle IS NOT NULL AND EXISTS (
           SELECT 1 FROM type_tache
            WHERE cle_de_libelle(libelle) = cle_de_libelle(v_libelle)
              AND id_type_tache IS DISTINCT FROM p_type) THEN
        RAISE EXCEPTION 'Le type « % » existe déjà', v_libelle
              USING ERRCODE = 'unique_violation';
    END IF;
    IF p_couleur IS NOT NULL AND p_couleur !~ '^#[0-9A-Fa-f]{6}$' THEN
        RAISE EXCEPTION 'Une couleur s''écrit #RRGGBB'
              USING ERRCODE = 'check_violation';
    END IF;
    IF p_duree_minutes IS NOT NULL AND (p_duree_minutes < 1 OR p_duree_minutes > 480) THEN
        RAISE EXCEPTION 'La durée va de 1 minute à 8 heures'
              USING ERRCODE = 'check_violation';
    END IF;
    IF p_priorite IS NOT NULL AND (p_priorite < 1 OR p_priorite > 5) THEN
        RAISE EXCEPTION 'La priorité va de 1 à 5'
              USING ERRCODE = 'check_violation';
    END IF;

    IF p_type IS NULL THEN
        INSERT INTO type_tache (libelle, couleur, icone, duree_minutes, priorite, ordre)
        VALUES (v_libelle, upper(p_couleur),
                COALESCE(NULLIF(btrim(p_icone), ''), 'checklist'),
                COALESCE(p_duree_minutes, 15), COALESCE(p_priorite, 4),
                (SELECT COALESCE(max(ordre), 0) + 1 FROM type_tache))
        RETURNING id_type_tache INTO v_type;
        RETURN v_type;
    END IF;

    UPDATE type_tache
       SET libelle       = COALESCE(v_libelle, libelle),
           couleur       = COALESCE(upper(p_couleur), couleur),
           icone         = COALESCE(NULLIF(btrim(p_icone), ''), icone),
           duree_minutes = COALESCE(p_duree_minutes, duree_minutes),
           priorite      = COALESCE(p_priorite, priorite)
     WHERE id_type_tache = p_type;
    RETURN p_type;
END $$;

COMMENT ON FUNCTION enregistrer_type_tache(INTEGER, TEXT, TEXT, TEXT, INTEGER, INTEGER) IS
    'TAC-25, TAC-26 : crée un type (sans numéro) ou le modifie. Refuse un nom
     déjà pris, sans égard à la casse ni aux accents.';

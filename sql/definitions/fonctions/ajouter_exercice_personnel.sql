-- -----------------------------------------------------------------------------
-- Ajouter un exercice hors catalogue                                    (EXO-11)
--
-- Le nom vient de l'utilisateur, le reste de HAL, qui l'a reconnu. Le même nom
-- déjà ajouté par ce compte rend le même exercice : un envoi répété ne crée
-- pas de doublon. Le code, interne, se tire du numéro.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION ajouter_exercice_personnel(
    p_utilisateur INTEGER,
    p_libelle     TEXT,
    p_discipline  VARCHAR,
    p_groupe      VARCHAR,
    p_secondaires TEXT[],
    p_materiel    VARCHAR,
    p_unilateral  BOOLEAN,
    p_mesure      VARCHAR,
    p_consigne    TEXT DEFAULT NULL
) RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE
    v_libelle  TEXT := btrim(regexp_replace(COALESCE(p_libelle, ''), '\s+', ' ', 'g'));
    v_exercice INTEGER;
BEGIN
    IF v_libelle = '' OR length(v_libelle) > 100 THEN
        RAISE EXCEPTION 'Le nom d''un exercice fait de 1 à 100 caractères'
              USING ERRCODE = 'check_violation';
    END IF;

    SELECT e.id_exercice INTO v_exercice
      FROM exercice e
     WHERE e.id_utilisateur = p_utilisateur AND lower(e.libelle) = lower(v_libelle);
    IF v_exercice IS NOT NULL THEN
        UPDATE exercice SET actif = TRUE WHERE id_exercice = v_exercice;
        RETURN v_exercice;
    END IF;

    v_exercice := nextval(pg_get_serial_sequence('exercice', 'id_exercice'));
    INSERT INTO exercice (id_exercice, code, libelle, discipline, groupe_principal,
                          groupes_secondaires, materiel, unilateral, mesure, consigne,
                          id_utilisateur)
    VALUES (v_exercice, 'perso_' || v_exercice, v_libelle, p_discipline, p_groupe,
            COALESCE(p_secondaires, '{}'), p_materiel, COALESCE(p_unilateral, FALSE),
            p_mesure, NULLIF(btrim(p_consigne), ''), p_utilisateur);
    RETURN v_exercice;
END $$;

COMMENT ON FUNCTION ajouter_exercice_personnel IS
    'EXO-11 : ajoute au catalogue de ce compte seul un exercice que HAL a
     reconnu par son nom. Le même nom rend le même exercice.';

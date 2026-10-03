-- -----------------------------------------------------------------------------
-- Remplacer les ouvertures d'un lieu                                    (SPT-15)
--
-- Le remplacement est en bloc : un créneau supprimé à la source doit
-- disparaître d'ici, sinon le moteur proposerait une séance devant une porte
-- close.
--
-- Mais une liste vide ne remplace rien. C'est la leçon du planning de travail :
-- une collecte muette avait effacé deux semaines de services. Une page qui ne
-- répond plus, une refonte du site, une session expirée — dans tous ces cas on
-- garde ce qu'on avait et on le signale.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION remplacer_ouvertures(
    p_code      VARCHAR,
    p_creneaux  JSONB
) RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE
    v_lieu   INTEGER;
    v_nombre INTEGER;
BEGIN
    SELECT id_lieu INTO v_lieu FROM lieu_sport WHERE code = p_code;
    IF v_lieu IS NULL THEN
        RAISE EXCEPTION 'Lieu % inconnu', p_code USING ERRCODE = 'no_data_found';
    END IF;

    v_nombre := jsonb_array_length(COALESCE(p_creneaux, '[]'::JSONB));
    IF v_nombre = 0 THEN
        RAISE EXCEPTION 'Relevé vide : les horaires existants sont conservés'
              USING ERRCODE = 'no_data_found';
    END IF;

    DELETE FROM ouverture WHERE id_lieu = v_lieu;

    INSERT INTO ouverture (id_lieu, jour_semaine, heure_debut, heure_fin)
    SELECT v_lieu,
           (c ->> 'jour')::SMALLINT,
           (c ->> 'debut')::TIME,
           (c ->> 'fin')::TIME
      FROM jsonb_array_elements(p_creneaux) c
    ON CONFLICT (id_lieu, jour_semaine, heure_debut) DO NOTHING;

    UPDATE lieu_sport
       SET horaires_releves_le = now()
     WHERE id_lieu = v_lieu;

    RETURN v_nombre;
END $$;

COMMENT ON FUNCTION remplacer_ouvertures IS
    'Remplace en bloc les créneaux d''ouverture d''un lieu. Refuse une liste
     vide plutôt que de tout effacer (SPT-15).';

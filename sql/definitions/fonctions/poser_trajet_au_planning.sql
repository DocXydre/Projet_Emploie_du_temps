-- -----------------------------------------------------------------------------
-- Un train se voit dans le planning                                    (TRJ-11)
--
-- Le trajet devient une occupation de type « autre » : elle s'affiche, elle
-- compte pour le placement des tâches, et elle échappe à la contrainte de
-- non-chevauchement (COL-15). Un train qui recouvre un cours est donc accepté,
-- c'est un choix qu'on a le droit de faire.
--
-- La clé externe porte l'identifiant du trajet : reposer le même trajet ne crée
-- pas de doublon, et l'annuler retire exactement la bonne ligne.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION poser_trajet_au_planning(p_trajet BIGINT)
RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE
    t        trajet;
    v_source INTEGER;
    v_ligne  INTEGER;
BEGIN
    SELECT * INTO t FROM trajet WHERE id_trajet = p_trajet;
    IF NOT FOUND THEN
        RETURN NULL;
    END IF;

    SELECT id_source INTO v_source FROM source WHERE code = 'MANUELLE';

    INSERT INTO occupation (id_utilisateur, id_source, type, libelle, lieu,
                            periode, cle_externe, details)
    VALUES (t.id_utilisateur, v_source, 'autre',
            format('Train %s → %s', t.origine, t.destination),
            t.destination, t.periode, format('trajet-%s', t.id_trajet),
            COALESCE(t.resume, 'Billet'))
    -- L'unicité porte sur (source, clé) : c'est elle qu'on vise.
    ON CONFLICT (id_source, cle_externe) DO UPDATE
       SET periode = EXCLUDED.periode,
           libelle = EXCLUDED.libelle,
           lieu    = EXCLUDED.lieu
    RETURNING id_occupation INTO v_ligne;

    RETURN v_ligne;
END $$;

COMMENT ON FUNCTION poser_trajet_au_planning IS
    'Affiche un train retenu dans le planning, en occupation « autre » : elle
     peut chevaucher un cours, c''est un choix assumé (TRJ-11).';

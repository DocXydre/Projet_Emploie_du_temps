-- -----------------------------------------------------------------------------
-- Un cours dit annulé                                                 (POS-11)
--
-- Il quitte le planning, et sa clé est gardée pour que la collecte suivante ne
-- le ramène pas. Son créneau se libère : le placement qui suit peut s'en
-- servir. Seul un cours collecté, à soi, pas encore fini, s'annule ainsi ; un
-- créneau posé à la main se retire comme d'habitude.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION annuler_cours(p_utilisateur INTEGER, p_occupation INTEGER)
RETURNS JSONB LANGUAGE plpgsql AS $$
DECLARE
    o occupation;
BEGIN
    SELECT * INTO o FROM occupation
     WHERE id_occupation = p_occupation AND id_utilisateur = p_utilisateur;
    IF NOT FOUND THEN
        PERFORM refus_coach('introuvable', 'Ce cours n''est pas dans ton planning');
    END IF;
    IF o.type <> 'cours' OR o.cle_externe IS NULL THEN
        PERFORM refus_coach('requete_invalide',
            'Seul un cours venu de l''emploi du temps s''annule ainsi ; un créneau posé '
            || 'à la main se retire');
    END IF;
    IF upper(o.periode) <= now() THEN
        PERFORM refus_coach('requete_invalide', 'Ce cours est déjà fini');
    END IF;

    INSERT INTO cours_annule (id_source, cle_externe, id_utilisateur, libelle, periode)
    VALUES (o.id_source, o.cle_externe, o.id_utilisateur, o.libelle, o.periode)
    ON CONFLICT (id_source, cle_externe) DO NOTHING;
    DELETE FROM occupation WHERE id_occupation = o.id_occupation;

    RETURN jsonb_build_object('id_occupation', o.id_occupation, 'libelle', o.libelle,
                              'debut', lower(o.periode), 'fin', upper(o.periode));
END $$;

COMMENT ON FUNCTION annuler_cours(INTEGER, INTEGER) IS
    'POS-11 : retire un cours dit annulé ; la collecte ne le ramène pas.';

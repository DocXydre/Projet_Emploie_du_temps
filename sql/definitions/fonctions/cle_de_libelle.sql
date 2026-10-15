-- -----------------------------------------------------------------------------
-- Un libellé ramené à sa forme comparable                              (TAC-26)
--
-- « Ménage », « menage » et « MÉNAGE » sont le même type. Sans l'extension
-- unaccent, que le serveur n'installe pas, les lettres accentuées du français
-- sont ramenées à la main.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION cle_de_libelle(p_libelle TEXT)
RETURNS TEXT LANGUAGE sql IMMUTABLE AS $$
    SELECT translate(lower(btrim(regexp_replace(COALESCE(p_libelle, ''), '\s+', ' ', 'g'))),
                     'àâäáãåçéèêëíìîïñóòôöõúùûüýÿœæ',
                     'aaaaaaceeeeiiiinooooouuuuyyoa')
$$;

COMMENT ON FUNCTION cle_de_libelle(TEXT) IS
    'TAC-26 : un libellé sans casse, sans accents et sans espaces doublés, pour
     comparer deux noms de type.';

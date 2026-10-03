-- -----------------------------------------------------------------------------
-- De quoi parle une ligne du journal                                    (JRN-3)
--
-- Le journal garde un nom lisible à côté de l'identifiant. Une occurrence
-- supprimée ne se retrouve plus par jointure, et « occurrence 4312 » ne dit
-- rien à personne.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION libelle_journal(p_table TEXT, p_ligne JSONB)
RETURNS TEXT LANGUAGE sql STABLE AS $$
    SELECT CASE p_table
        WHEN 'occurrence' THEN
            (SELECT t.libelle FROM tache t
              WHERE t.id_tache = (p_ligne ->> 'id_tache')::INTEGER)
        WHEN 'absence'     THEN COALESCE(NULLIF(p_ligne ->> 'lieu', ''), 'Absence')
        WHEN 'proposition' THEN 'Week-end à ' || COALESCE(p_ligne ->> 'lieu', '?')
        WHEN 'trajet'      THEN COALESCE(NULLIF(p_ligne ->> 'resume', ''),
                                         (p_ligne ->> 'origine') || ' → '
                                         || (p_ligne ->> 'destination'))
        WHEN 'courriel'    THEN left(p_ligne ->> 'sujet', 120)
        -- Le texte sans ses balises, et coupé : le bilan du matin fait une page.
        WHEN 'notification' THEN
            left(regexp_replace(p_ligne ->> 'contenu', '<[^>]+>', '', 'g'), 120)
        WHEN 'utilisateur' THEN p_ligne ->> 'nom'
        WHEN 'allegement'  THEN 'Mode allégé'
        ELSE p_ligne ->> 'libelle'
    END
$$;

COMMENT ON FUNCTION libelle_journal(TEXT, JSONB) IS
    'JRN-3 : le nom en clair de ce qu''une ligne du journal concerne.';

-- =============================================================================
-- 085 : les lieux de sport décrits                          (ADR-11, ADR-15 à ADR-18)
--
-- Rejouable.
--
-- L'écran « Lieux de sport » est retiré : les lieux de chaque discipline se
-- déduisent des adresses (`lieux_de_sport()`), et chaque lieu a une
-- description, que HAL tient et lit pour choisir où placer une séance. La
-- mémoire d'un lieu, créée par la 084, devient sa description : même table,
-- même versions, autre nom.
--
-- `discipline_lieu` reste, pour les comptes qui n'ont encore donné l'adresse
-- d'aucun lieu de sport (ADR-18).
-- =============================================================================

DO $$
BEGIN
    IF to_regclass('public.memoire_lieu') IS NOT NULL
       AND to_regclass('public.description_lieu') IS NULL THEN
        ALTER TABLE memoire_lieu RENAME TO description_lieu;
        ALTER TABLE description_lieu RENAME COLUMN id_memoire_lieu TO id_description_lieu;
        ALTER INDEX IF EXISTS memoire_lieu_en_vigueur RENAME TO description_lieu_en_vigueur;
    END IF;
END $$;

DROP FUNCTION IF EXISTS ecrire_memoire_lieu(INTEGER, INTEGER, TEXT, VARCHAR);

COMMENT ON TABLE description_lieu IS
    'ADR-11 : la description d''un lieu pour un compte, ce que HAL lit pour choisir le lieu d''une séance. Une ligne par version ; la dernière est en vigueur.';

COMMENT ON TABLE discipline_lieu IS
    'LIE-1, ADR-18 : les lieux choisis par discipline, avant les adresses. Ne sert plus qu''aux comptes sans lieu de sport avec adresse.';

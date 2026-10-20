-- =============================================================================
-- 073 : un exercice hors catalogue, à soi                               (EXO-11)
--
-- Rejouable.
--
-- Un exercice absent du catalogue s'ajoute par son nom. HAL le reconnaît
-- (groupe, matériel, mesure) et il rejoint le catalogue de ce compte seul :
-- l'autre ne le voit pas, et le coach ne le propose qu'à lui.
-- =============================================================================

ALTER TABLE exercice ADD COLUMN IF NOT EXISTS id_utilisateur INTEGER REFERENCES utilisateur;

COMMENT ON COLUMN exercice.id_utilisateur IS
    'EXO-11 : le compte qui a ajouté cet exercice, seul à le voir. Vide pour le
     catalogue commun.';

-- Un même nom ne s'ajoute qu'une fois par compte.
CREATE UNIQUE INDEX IF NOT EXISTS exercice_personnel_unique
    ON exercice (id_utilisateur, lower(libelle)) WHERE id_utilisateur IS NOT NULL;

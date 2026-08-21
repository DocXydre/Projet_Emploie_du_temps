-- rejouable : ce fichier ne contient que des CREATE OR REPLACE ou des IF NOT
--             EXISTS. Le rejouer après modification est sans effet de bord.
-- =============================================================================
-- 007 — Jeton d'abonnement au calendrier                                  (R61)
-- =============================================================================
-- Jusqu'ici le flux iCalendar s'authentifiait avec la clé d'API. Cette clé
-- voyage alors dans une URL que le téléphone garde en clair, recopie dans ses
-- sauvegardes et transmet à chaque rafraîchissement. Si elle fuite, elle donne
-- accès à toute l'API : déclarer des absences, valider des tâches, changer les
-- sources.
--
-- On sépare donc les deux. Le jeton de calendrier ne permet que de lire le
-- planning, et se renouvelle en une requête sans rien casser d'autre — il
-- suffit de réabonner le téléphone.
--
-- Cette migration est écrite pour être rejouable : sur une base neuve, la
-- colonne existe déjà (001), et tout ce qui suit devient sans effet.
-- =============================================================================

ALTER TABLE utilisateur
    ADD COLUMN IF NOT EXISTS jeton_calendrier VARCHAR(64)
        DEFAULT replace(gen_random_uuid()::TEXT, '-', '');

-- Les comptes créés avant cette migration n'en ont pas : le DEFAULT ne
-- s'applique qu'aux lignes futures.
UPDATE utilisateur
   SET jeton_calendrier = replace(gen_random_uuid()::TEXT, '-', '')
 WHERE jeton_calendrier IS NULL;

ALTER TABLE utilisateur ALTER COLUMN jeton_calendrier SET NOT NULL;

-- Le nom est celui qu'engendre la contrainte UNIQUE de 001 : sur une base
-- neuve, l'index porte déjà ce nom et rien n'est créé.
CREATE UNIQUE INDEX IF NOT EXISTS utilisateur_jeton_calendrier_key
    ON utilisateur (jeton_calendrier);

COMMENT ON COLUMN utilisateur.jeton_calendrier IS
    'Abonnement iCalendar seul. Distinct de la clé d''API car il voyage dans '
    'une URL que le téléphone conserve en clair : s''il fuite, il ne donne que '
    'la lecture du planning, et se renouvelle sans rien casser d''autre (R61).';


-- -----------------------------------------------------------------------------
-- Renouvellement                                                          (R62)
-- -----------------------------------------------------------------------------
-- Révoquer, c'est remplacer. Les abonnements existants cessent aussitôt de
-- fonctionner, ce qui est précisément l'effet recherché.
CREATE OR REPLACE FUNCTION renouveler_jeton_calendrier(p_utilisateur INTEGER)
RETURNS VARCHAR LANGUAGE sql AS $$
    UPDATE utilisateur
       SET jeton_calendrier = replace(gen_random_uuid()::TEXT, '-', '')
     WHERE id_utilisateur = p_utilisateur AND actif
    RETURNING jeton_calendrier;
$$;

COMMENT ON FUNCTION renouveler_jeton_calendrier IS
    'Invalide l''abonnement calendrier en place et en rend un nouveau (R62).';

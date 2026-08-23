-- rejouable : ce fichier ne contient que des CREATE OR REPLACE ou des IF NOT
--             EXISTS. Le rejouer après modification est sans effet de bord.
-- =============================================================================
-- 007 : jeton d'abonnement au calendrier                              (UTI-2)
--
-- Le flux iCalendar s'authentifiait avec la clé d'API. Or cette URL est
-- conservée en clair par le téléphone et rejouée à chaque rafraîchissement :
-- si elle fuite, elle ouvre toute l'API.
--
-- Le jeton de calendrier ne donne que la lecture du planning, et se renouvelle
-- sans toucher au reste.
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
    'la lecture du planning, et se renouvelle sans rien casser d''autre (UTI-2).';


-- -----------------------------------------------------------------------------
-- Renouvellement                                                          (UTI-3)
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
    'Invalide l''abonnement calendrier en place et en rend un nouveau (UTI-3).';

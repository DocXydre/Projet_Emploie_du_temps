-- =============================================================================
-- 074 : le sport sans montre                                  (MON-7 à MON-15)
--
-- Rejouable.
--
-- Chaque compte dit s'il a une Apple Watch. Sans elle, l'appli retire ce qui
-- ne vit que par la montre, une course reçue d'une autre appli demande sa note
-- d'effort, et une course sans rien qui l'enregistre se déclare à la main.
-- Les comptes qui existent ont la montre : rien ne change pour eux.
-- =============================================================================

ALTER TABLE utilisateur ADD COLUMN IF NOT EXISTS a_une_montre BOOLEAN NOT NULL DEFAULT TRUE;

COMMENT ON COLUMN utilisateur.a_une_montre IS
    'MON-7 : l''interrupteur « J''ai une Apple Watch », réglé à la main. Faux, l''appli
     retire ce qui ne vit que par la montre (MON-8) et HAL dose la course sans
     fréquence cardiaque (MON-15).';

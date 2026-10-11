-- =============================================================================
-- 058 : ce que coûte vraiment un appel au coach                       (COA-21)
--
-- Rejouable.
--
-- Le fournisseur facture quatre choses à des prix différents : ce qui est lu
-- pour la première fois, ce qui est écrit dans son cache (1,25 fois plus cher),
-- ce qui est relu depuis le cache (20 fois moins cher) et ce qui est écrit en
-- réponse. Jusqu'ici, l'écriture dans le cache n'était pas comptée à part : on
-- ne pouvait pas savoir où partait l'argent.
-- =============================================================================

ALTER TABLE appel_coach
    ADD COLUMN IF NOT EXISTS tokens_cache_ecrit INTEGER NOT NULL DEFAULT 0;

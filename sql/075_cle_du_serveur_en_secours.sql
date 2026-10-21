-- =============================================================================
-- 075 : la clé du serveur reste en secours                              (FOU-1)
--
-- Rejouable.
--
-- Brancher son abonnement Claude retirait la clé d'API du serveur, qui servait
-- tant que rien n'était branché : HAL n'avait plus de secours quand
-- l'abonnement était épuisé. Elle revient derrière les fournisseurs de chaque
-- compte qui n'a pas d'API, comme fournisseur `api` sans secret, avec le
-- plafond par défaut. Elle se coupe d'un interrupteur dans Réglages.
-- =============================================================================

INSERT INTO fournisseur_modele (id_utilisateur, type, rang)
SELECT f.id_utilisateur, 'api', max(f.rang) + 1
  FROM fournisseur_modele f
 GROUP BY f.id_utilisateur
HAVING NOT bool_or(f.type = 'api')
ON CONFLICT (id_utilisateur, type) DO NOTHING;

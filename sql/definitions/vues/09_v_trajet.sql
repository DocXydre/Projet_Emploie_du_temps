-- -----------------------------------------------------------------------------
-- Vue : propositions encore valables
--
-- Une proposition dont le train est parti n'est plus une proposition. Plutôt
-- que de faire tourner un nettoyage, on la laisse en base et la vue cesse de
-- la montrer : l'historique reste lisible, et rien ne dépend d'un balayage.
-- -----------------------------------------------------------------------------
CREATE VIEW v_trajet AS
SELECT t.id_trajet,
       t.id_utilisateur,
       u.pseudo,
       t.sens,
       lower(t.periode)                                   AS depart,
       upper(t.periode)                                   AS arrivee,
       upper(t.periode) - lower(t.periode)                AS duree,
       t.origine,
       t.destination,
       t.correspondances,
       t.resume,
       t.statut,
       t.id_trajet_aller,
       t.id_absence,
       (t.statut = 'proposee' AND lower(t.periode) > now()) AS encore_valable
  FROM trajet t
  JOIN utilisateur u ON u.id_utilisateur = t.id_utilisateur;

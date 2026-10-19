CREATE VIEW v_echantillon_sante AS
SELECT e.id_utilisateur, e.cle_externe, e.grandeur, e.periode, e.valeur, e.source,
       e.appareil, e.de_la_montre
  FROM echantillon_sante e
 WHERE e.de_la_montre
    OR NOT EXISTS (SELECT 1 FROM echantillon_sante m
                    WHERE m.id_utilisateur = e.id_utilisateur
                      AND m.grandeur = e.grandeur
                      AND m.de_la_montre
                      AND m.periode && e.periode);

COMMENT ON VIEW v_echantillon_sante IS
    'SAN-15 : les mesures du quotidien telles qu''on les lit. Tout est gardé
     dans echantillon_sante ; ici, une mesure d''une autre source qui recouvre
     une mesure de la montre de la même grandeur est laissée de côté.';
